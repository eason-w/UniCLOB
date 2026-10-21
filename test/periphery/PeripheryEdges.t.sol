// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PeripheryBase, Book, Router, Manager, MockERC20, PermitMock, RejectNative } from "./Periphery.t.sol";
import { RangeBookQuoter as Quoter } from "../../src/periphery/RangeBookQuoter.sol";
import { ConcentratedRangeBookLens as Lens } from "../../src/periphery/RangeBookLens.sol";
import { PeripheryPayments } from "../../src/periphery/PeripheryPayments.sol";
import { LiquidityAmounts } from "../../src/periphery/LiquidityAmounts.sol";
import { TickMath } from "../../src/vendor/uniswap/TickMath.sol";
import { CallbackToken } from "../mocks/HostileTokens.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Taxes only manager-to-user transfers, after the core has successfully paid the manager.
contract ExitTaxToken is MockERC20 {
    address public taxedSender;
    constructor() MockERC20("Exit tax", "EXIT", 18) { }

    function setTaxedSender(address sender) external {
        taxedSender = sender;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == taxedSender && from != address(0) && amount != 0) {
            super._update(from, address(0), 1);
            --amount;
        }
        super._update(from, to, amount);
    }
}

/// @notice WETH-shaped adversary that can underpay either wrapping or unwrapping by one atom.
contract ShortWrapped is MockERC20 {
    bool public shortDeposit;
    bool public shortWithdraw;
    constructor() MockERC20("Short wrapper", "SHORT", 18) { }

    function configure(bool deposit_, bool withdraw_) external {
        shortDeposit = deposit_;
        shortWithdraw = withdraw_;
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value - (shortDeposit ? 1 : 0));
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{ value: amount - (shortWithdraw ? 1 : 0) }("");
        require(ok);
    }
}

/// @notice Accepts ordinary safe transfers, but can reject receipt to verify atomic NFT ownership.
contract NFTRecipient is IERC721Receiver {
    bool public reject;

    function setReject(bool value) external {
        reject = value;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(!reject, "NFT rejected");
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Integration edge cases assert specific failure causes and rollback of custody or ownership.
contract PeripheryEdgesTest is PeripheryBase {
    function _pool(MockERC20 a, MockERC20 b) internal returns (bytes32 id) {
        id = book.createMarket(Book.Config(address(a), address(b), LOT, 10, 500, 4, Q96));
        a.mint(lp, 1e30);
        b.mint(lp, 1e30);
        vm.startPrank(lp);
        a.approve(address(book), type(uint256).max);
        b.approve(address(book), type(uint256).max);
        book.deposit(address(a), 1e30, lp);
        book.deposit(address(b), 1e30, lp);
        book.mint(id, -887_270, 887_270, L, type(uint256).max, type(uint256).max, NEVER);
        vm.stopPrank();
    }

    function _path() internal view returns (Router.ExactInputParams memory p) {
        Router.Hop[] memory path = new Router.Hop[](1);
        path[0] = Router.Hop(market, address(token0), 0, 128);
        p = Router.ExactInputParams(address(token1), path, taker, 1e18, 0, NEVER, false);
    }

    function _invalidPath(Router.ExactInputParams memory p) internal {
        bytes32 before_ = stateHash();
        uint256 balance = token1.balanceOf(taker);
        vm.expectRevert(Quoter.InvalidPath.selector);
        quoter.quoteExactInput(p);
        vm.prank(taker);
        vm.expectRevert(Router.InvalidPath.selector);
        router.exactInput(p);
        assertEq(stateHash(), before_);
        assertEq(token1.balanceOf(taker), balance);
        assertEq(token1.balanceOf(address(router)), 0);
    }

    function test_PathValidationRejectsLengthAssetsAndZeroInput() public {
        Router.ExactInputParams memory p = _path();
        p.path = new Router.Hop[](0);
        _invalidPath(p);
        p.path = new Router.Hop[](9);
        _invalidPath(p);
        p = _path();
        p.path[0].tokenOut = address(wrapped);
        _invalidPath(p);
        p = _path();
        p.tokenIn = address(token0); // input and output are the same asset
        _invalidPath(p);
        p = _path();
        p.amountIn = 0;
        _invalidPath(p);
    }

    function test_ConnectedRepeatedMarketRouteIsRejectedByRouterAndQuoter() public {
        Router.ExactInputParams memory p = _path();
        p.path = new Router.Hop[](2);
        p.path[0] = Router.Hop(market, address(token0), 0, 128);
        p.path[1] = Router.Hop(market, address(token1), 0, 128);
        _invalidPath(p);
    }

    function test_IntermediateOverflowIsRejectedBeforeSecondHop() public {
        Router.ExactInputParams memory p = _path();
        p.path = new Router.Hop[](2);
        p.path[0] = Router.Hop(market, address(token0), 0, 128);
        p.path[1] = Router.Hop(bytes32(uint256(123)), address(wrapped), 0, 128);
        Book.TradeResult memory oversized;
        oversized.input = p.amountIn;
        oversized.output = uint256(type(uint128).max) + 1;
        // Isolate router/quoter's defensive cast check; this mock is not a matching-equivalence test.
        vm.mockCallRevert(
            address(book),
            abi.encodeWithSelector(Book.quoteTrade.selector),
            abi.encodeWithSelector(Book.QuoteResult.selector, oversized)
        );
        vm.mockCall(address(book), abi.encodeWithSelector(Book.swapWallet.selector), abi.encode(oversized));
        _invalidPath(p);
    }

    function test_QuoterRejectsSuccessfulOrMalformedCoreResponses() public {
        bytes memory call_ = abi.encodeWithSelector(Book.quoteTrade.selector);
        vm.mockCall(address(book), call_, bytes(""));
        vm.expectRevert(Quoter.InvalidQuoteResponse.selector);
        quoter.quoteTrade(request(false, 1e18));
        vm.clearMockedCalls();
        for (uint256 i; i < 3; ++i) {
            bytes memory data = abi.encodePacked(Book.QuoteResult.selector, new bytes(i == 0 ? 0 : i == 1 ? 191 : 193));
            vm.mockCallRevert(address(book), call_, data);
            vm.expectRevert(Quoter.InvalidQuoteResponse.selector);
            quoter.quoteTrade(request(false, 1e18));
        }
        bytes memory shortError = hex"abcdef";
        vm.mockCallRevert(address(book), call_, shortError);
        vm.expectRevert(shortError);
        quoter.quoteTrade(request(false, 1e18));
        vm.mockCallRevert(address(book), call_, bytes(""));
        vm.expectRevert(bytes(""));
        quoter.quoteTrade(request(false, 1e18));
    }

    function test_MarketCreationBubblesUnexpectedProbeError() public {
        bytes memory reason = abi.encodeWithSignature("ProbeFailure(uint256)", 7);
        vm.mockCallRevert(address(book), abi.encodeWithSelector(Book.getMarket.selector), reason);
        vm.expectRevert(reason);
        manager.createAndInitializeMarketIfNecessary(config());
        // A malformed UnknownMarket payload must not be mistaken for the expected missing-market signal.
        reason = abi.encodePacked(Book.UnknownMarket.selector, uint256(1));
        vm.mockCallRevert(address(book), abi.encodeWithSelector(Book.getMarket.selector), reason);
        vm.expectRevert(reason);
        manager.createAndInitializeMarketIfNecessary(config());
    }

    function test_ConstructorsRejectMissingCodeAndAllowDisabledNative() public {
        vm.expectRevert(PeripheryPayments.InvalidAddress.selector);
        new Router(Book(address(0)), address(wrapped));
        vm.expectRevert(PeripheryPayments.InvalidAddress.selector);
        new Manager(book, address(123));
        vm.expectRevert(Quoter.InvalidCore.selector);
        new Quoter(Book(address(0)));
        vm.expectRevert(Lens.InvalidQuery.selector);
        new Lens(Book(address(0)));
        Router disabled = new Router(book, address(0));
        Manager disabledManager = new Manager(book, address(0));
        assertEq(disabled.wrappedNative(), address(0));
        assertEq(disabledManager.wrappedNative(), address(0));
        Router.ExactInputSingleParams memory p = params(false, 1e18);
        p.unwrapNative = true;
        vm.expectRevert(PeripheryPayments.InvalidNativeValue.selector);
        disabled.exactInputSingle(p);
        vm.deal(taker, 1 ether);
        vm.prank(taker);
        (bool ok, bytes memory error_) = address(router).call{ value: 1 }("");
        assertFalse(ok);
        assertEq(error_, abi.encodeWithSelector(PeripheryPayments.InvalidNativeValue.selector));
    }

    function test_ZeroInputAndInvalidRecipientsFailBeforeFunding() public {
        Router.ExactInputSingleParams memory p = params(false, 0);
        vm.expectRevert(Router.InvalidPath.selector);
        router.exactInputSingle(p);
        p = params(false, 1e18);
        p.recipient = address(0);
        vm.expectRevert(PeripheryPayments.InvalidAddress.selector);
        router.exactInputSingle(p);
        p.recipient = address(book);
        vm.expectRevert(PeripheryPayments.InvalidAddress.selector);
        router.exactInputSingle(p);
        p = params(false, 1e18);
        p.tokenIn = address(wrapped);
        vm.expectRevert(Quoter.InvalidPath.selector);
        quoter.quoteExactInputSingle(p);
    }

    function test_MultihopNativeOutputMatchesQuoteAndPreservesDonations() public {
        bytes32 second = _pool(token0, wrapped);
        Router.ExactInputParams memory p = _path();
        p.path = new Router.Hop[](2);
        p.path[0] = Router.Hop(market, address(token0), 0, 128);
        p.path[1] = Router.Hop(second, address(wrapped), 0, 128);
        p.unwrapNative = true;
        (uint256 expected,) = quoter.quoteExactInput(p);
        p.amountOutMinimum = expected;
        wrapped.mint(address(router), 13);
        token0.mint(address(router), 17);
        vm.deal(address(router), 19);
        uint256 before_ = taker.balance;
        vm.prank(taker);
        assertEq(router.exactInput(p), expected);
        assertEq(taker.balance, before_ + expected);
        assertEq(wrapped.balanceOf(address(router)), 13);
        assertEq(token0.balanceOf(address(router)), 17);
        assertEq(address(router).balance, 19);
    }

    function test_MultihopNativeInputAndRejectedOutputRollbackBothMarkets() public {
        bytes32 first = _pool(token0, wrapped);
        Router.ExactInputParams memory p = _path();
        p.tokenIn = address(wrapped);
        p.path = new Router.Hop[](2);
        p.path[0] = Router.Hop(first, address(token0), 0, 128);
        p.path[1] = Router.Hop(market, address(token1), 0, 128);
        (uint256 expected,) = quoter.quoteExactInput(p);
        uint256 before_ = token1.balanceOf(taker);
        vm.deal(taker, 2 ether);
        vm.prank(taker);
        assertEq(router.exactInput{ value: 1 ether }(p), expected);
        assertEq(token1.balanceOf(taker), before_ + expected);
        assertEq(taker.balance, 1 ether);
        p.tokenIn = address(token1);
        p.path[0] = Router.Hop(market, address(token0), 0, 128);
        p.path[1] = Router.Hop(first, address(wrapped), 0, 128);
        p.unwrapNative = true;
        p.recipient = address(new RejectNative());
        bytes32 oldState = stateHash();
        (, uint160 price,,) = book.getMarket(first);
        before_ = token1.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(PeripheryPayments.NativeTransferFailed.selector);
        router.exactInput(p);
        assertEq(stateHash(), oldState);
        (, uint160 afterPrice,,) = book.getMarket(first);
        assertEq(afterPrice, price);
        assertEq(token1.balanceOf(taker), before_);
    }

    function test_NativeValueAndUnwrapFlagsRejectIncompatibleAssets() public {
        (uint256 position,) = nft();
        vm.prank(lp2);
        vm.expectRevert(PeripheryPayments.InvalidNativeValue.selector);
        manager.collect(position, lp2, true);
        Manager.MintParams memory m = mintParams(-600, 600);
        vm.deal(lp2, 10 ether);
        vm.prank(lp2);
        vm.expectRevert(PeripheryPayments.InvalidNativeValue.selector);
        manager.mint{ value: 1 }(m);
        m.marketId = _pool(wrapped, token1);
        vm.prank(lp2);
        vm.expectRevert(PeripheryPayments.InvalidNativeValue.selector);
        manager.mint{ value: 1 }(m); // differs from declared desired amount
        Router.ExactInputParams memory p = _path();
        p.unwrapNative = true;
        vm.expectRevert(PeripheryPayments.InvalidNativeValue.selector);
        router.exactInput(p);
        Router.ExactInputSingleParams memory s = params(true, 1e18);
        s.marketId = m.marketId;
        s.tokenIn = address(wrapped);
        vm.deal(taker, 10 ether);
        vm.prank(taker);
        vm.expectRevert(PeripheryPayments.InvalidNativeValue.selector);
        router.exactInputSingle{ value: 1 }(s);
    }

    function test_ShortWrappingAndUnwrappingRevertWithoutLosingInput() public {
        ShortWrapped short = new ShortWrapped();
        vm.deal(address(short), 100 ether);
        bytes32 id = _pool(short, token1);
        Router r = new Router(book, address(short));
        Router.ExactInputSingleParams memory p = params(true, 1 ether);
        p.marketId = id;
        p.tokenIn = address(short);
        vm.deal(taker, 2 ether);
        short.configure(true, false);
        vm.prank(taker);
        vm.expectRevert(PeripheryPayments.UnsupportedAsset.selector);
        r.exactInputSingle{ value: 1 ether }(p);
        assertEq(taker.balance, 2 ether);
        assertEq(short.balanceOf(address(r)), 0);
        short.configure(false, true);
        p.tokenIn = address(token1);
        p.unwrapNative = true;
        vm.prank(taker);
        token1.approve(address(r), type(uint256).max);
        uint256 before_ = token1.balanceOf(taker);
        (, uint160 price,,) = book.getMarket(id);
        vm.prank(taker);
        vm.expectRevert(PeripheryPayments.UnsupportedAsset.selector);
        r.exactInputSingle(p);
        assertEq(token1.balanceOf(taker), before_);
        (, uint160 afterPrice,,) = book.getMarket(id);
        assertEq(afterPrice, price);
    }

    function test_TaxedManagerPayoutRollsBackLiquidityAndPrincipal() public {
        ExitTaxToken taxed = new ExitTaxToken();
        bytes32 id = _pool(taxed, token1);
        taxed.mint(lp2, 1e24);
        vm.prank(lp2);
        taxed.approve(address(manager), type(uint256).max);
        Manager.MintParams memory p = mintParams(-600, 600);
        p.marketId = id;
        vm.prank(lp2);
        (uint256 position, uint128 liquidity,,) = manager.mint(p);
        uint256 before_ = taxed.balanceOf(lp2);
        taxed.setTaxedSender(address(manager));
        vm.prank(lp2);
        vm.expectRevert(PeripheryPayments.UnsupportedAsset.selector);
        manager.decreaseLiquidity(Manager.DecreaseLiquidityParams(position, liquidity, 0, 0, lp2, NEVER, false));
        assertEq(book.getPosition(position).accounting.liquidity, liquidity);
        assertEq(taxed.balanceOf(lp2), before_);
        assertEq(taxed.balanceOf(address(manager)), 0);
    }

    function test_OneSidedToken1PositionAndNFTReceiverRollback() public {
        Manager.MintParams memory p = mintParams(-10_000, -100);
        p.amount0Desired = 0;
        vm.prank(lp2);
        (uint256 id,, uint256 a0, uint256 a1) = manager.mint(p);
        assertEq(a0, 0);
        assertGt(a1, 0);
        NFTRecipient receiver = new NFTRecipient();
        receiver.setReject(true);
        vm.prank(lp2);
        vm.expectRevert("NFT rejected");
        manager.safeTransferFrom(lp2, address(receiver), id);
        assertEq(manager.ownerOf(id), lp2);
        receiver.setReject(false);
        vm.prank(lp2);
        manager.safeTransferFrom(lp2, address(receiver), id);
        assertEq(manager.ownerOf(id), address(receiver));
        p.recipient = address(12_345); // EOA succeeds; a non-receiver contract below must roll back mint.
        p.recipient = address(token0);
        uint256 next = book.nextPositionId();
        uint256 before_ = token1.balanceOf(lp2);
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSignature("ERC721InvalidReceiver(address)", address(token0)));
        manager.mint(p);
        assertEq(book.nextPositionId(), next);
        assertEq(token1.balanceOf(lp2), before_);
    }

    function test_SecondAssetMinimumAndBurnedNFTCannotBeReused() public {
        Manager.MintParams memory p = mintParams(-600, 600);
        p.amount1Min = p.amount1Desired + 1;
        vm.prank(lp2);
        vm.expectRevert(PeripheryPayments.PeripherySlippage.selector);
        manager.mint(p);
        (uint256 id, uint128 liquidity) = nft();
        vm.startPrank(lp2);
        manager.decreaseLiquidity(Manager.DecreaseLiquidityParams(id, liquidity, 0, 0, lp2, NEVER, false));
        manager.burn(id);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", id));
        manager.increaseLiquidity(Manager.IncreaseLiquidityParams(id, 1e18, 1e18, 0, 0, NEVER));
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", id));
        manager.tokenURI(id);
        vm.stopPrank();
    }

    function test_LensRejectsBadRangesPagesAndUnknownMarkets() public {
        vm.expectRevert(Lens.InvalidQuery.selector);
        lens.quoteLiquidity(market, -601, 600, 1e18, 1e18);
        vm.expectRevert(Lens.InvalidQuery.selector);
        lens.quoteLiquidity(market, -600, 601, 1e18, 1e18);
        vm.expectRevert(LiquidityAmounts.InvalidLiquidityAmounts.selector);
        lens.quoteLiquidity(market, 600, -600, 1e18, 1e18);
        vm.expectRevert(LiquidityAmounts.InvalidLiquidityAmounts.selector);
        lens.quoteLiquidity(market, -600, 600, 0, 0);
        vm.expectRevert(LiquidityAmounts.InvalidLiquidityAmounts.selector);
        lens.quoteLiquidity(market, -600, 600, 1e50, 1e50);
        vm.expectRevert(Lens.InvalidQuery.selector);
        lens.ordersById(new uint256[](129));
        (Book.Order[] memory orders, uint128[] memory remaining, uint128[] memory claimable) =
            lens.ordersById(new uint256[](0));
        assertEq(orders.length + remaining.length + claimable.length, 0);
        vm.expectRevert(Book.UnknownMarket.selector);
        lens.orderDepth(bytes32(uint256(123)), true, 0, 1);
        vm.expectRevert(Book.UnknownMarket.selector);
        lens.quoteLiquidity(bytes32(uint256(123)), -600, 600, 1e18, 1e18);
    }

    function test_PermitSuccessSetsOnlyCallerAllowanceAndConsumesNonce() public {
        PermitMock token = new PermitMock();
        bytes32 id = _pool(MockERC20(address(token)), token1);
        uint256 key = 1234;
        address signer = vm.addr(key);
        token.mint(signer, 2 ether);
        Router.ExactInputSingleParams memory p = params(true, 1 ether);
        p.marketId = id;
        p.tokenIn = address(token);
        p.recipient = signer;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(router),
                p.amountIn,
                uint256(0),
                uint256(NEVER)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
        vm.prank(signer);
        Book.TradeResult memory result = router.exactInputSingleWithPermit(p, Router.Permit(NEVER, v, r, s));
        assertEq(token.nonces(signer), 1);
        assertEq(token.allowance(signer, address(router)), 0);
        assertEq(token.balanceOf(signer), 2 ether - result.input);
        assertEq(token1.balanceOf(signer), result.output);
    }

    function test_ExplicitPriceQuoteAndWorkLimitedFillMatchExecution() public {
        Router.ExactInputSingleParams memory p = params(false, 1e23);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(10);
        Book.TradeResult memory quoted = quoter.quoteExactInputSingle(p);
        assertLt(quoted.input, p.amountIn);
        p.allowPartial = false;
        vm.expectRevert(Book.IncompleteFill.selector);
        quoter.quoteExactInputSingle(p);
        p.allowPartial = true;
        vm.prank(taker);
        assertEq(abi.encode(router.exactInputSingle(p)), abi.encode(quoted));
        // A work-bound partial fill is distinct from a price-bound partial fill.
        order(true, 20, 100);
        p.sqrtPriceLimitX96 = 0;
        p.maxSteps = 1;
        quoted = quoter.quoteExactInputSingle(p);
        assertEq(quoted.steps, 1);
        assertLt(quoted.input, p.amountIn);
        vm.prank(taker);
        assertEq(abi.encode(router.exactInputSingle(p)), abi.encode(quoted));
    }

    function test_MaximumEightHopRouteMatchesQuoteWithoutSharedBalanceSweeps() public {
        Router.ExactInputParams memory p = _path();
        p.path = new Router.Hop[](8);
        for (uint256 i; i < 8; ++i) {
            Book.Config memory c = config();
            c.orderLot = uint128(LOT * (i + 2));
            bytes32 id = book.createMarket(c);
            vm.prank(lp);
            book.mint(id, -887_270, 887_270, L, type(uint256).max, type(uint256).max, NEVER);
            p.path[i] = Router.Hop(id, i % 2 == 0 ? address(token0) : address(token1), 0, 128);
        }
        token0.mint(address(router), 17);
        token1.mint(address(router), 19);
        (uint256 expected, Book.TradeResult[] memory hops) = quoter.quoteExactInput(p);
        assertEq(hops.length, 8);
        uint256 before_ = token1.balanceOf(taker);
        p.amountOutMinimum = expected;
        vm.prank(taker);
        assertEq(router.exactInput(p), expected);
        assertEq(token1.balanceOf(taker), before_ - p.amountIn + expected);
        assertEq(token0.balanceOf(address(router)), 17);
        assertEq(token1.balanceOf(address(router)), 19);
    }

    function test_CallbackMatrixProtectsEveryManagerMutation() public {
        CallbackToken token = new CallbackToken();
        bytes32 id = _pool(token, token1);
        token.mint(lp2, 1e24);
        vm.prank(lp2);
        token.approve(address(manager), type(uint256).max);
        Manager.MintParams memory p = mintParams(-600, 600);
        p.marketId = id;
        vm.prank(lp2);
        (uint256 position,,,) = manager.mint(p);
        Manager.IncreaseLiquidityParams memory increase =
            Manager.IncreaseLiquidityParams(position, 1e18, 1e18, 0, 0, NEVER);
        bytes[] memory payloads = new bytes[](7);
        payloads[0] = abi.encodeCall(Manager.mint, (p));
        payloads[1] = abi.encodeCall(Manager.increaseLiquidity, (increase));
        payloads[2] = abi.encodeCall(
            Manager.decreaseLiquidity, (Manager.DecreaseLiquidityParams(position, 1, 0, 0, lp2, NEVER, false))
        );
        payloads[3] = abi.encodeCall(Manager.collect, (position, lp2, false));
        payloads[4] = abi.encodeCall(Manager.burn, (position));
        payloads[5] = abi.encodeCall(Manager.transferFrom, (lp2, taker, position));
        payloads[6] = abi.encodeCall(Manager.createAndInitializeMarketIfNecessary, (config()));
        for (uint256 i; i < payloads.length; ++i) {
            token.configure(address(manager), payloads[i]);
            vm.prank(lp2);
            manager.increaseLiquidity(increase);
            assertTrue(token.attempted());
            assertFalse(token.succeeded());
            assertEq(
                token.returnData(),
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            );
            assertEq(manager.ownerOf(position), lp2);
            assertEq(token.balanceOf(address(manager)), 0);
        }
    }

    function test_CallbackMatrixProtectsEveryRouterMutation() public {
        CallbackToken token = new CallbackToken();
        bytes32 id = _pool(token, token1);
        token.mint(taker, 1e24);
        vm.prank(taker);
        token.approve(address(router), type(uint256).max);
        Router.ExactInputSingleParams memory p = params(true, 1e18);
        p.marketId = id;
        p.tokenIn = address(token);
        Router.ExactInputParams memory route = _path();
        route.tokenIn = address(token);
        route.path[0] = Router.Hop(id, address(token1), 0, 128);
        bytes[] memory payloads = new bytes[](3);
        payloads[0] = abi.encodeCall(Router.exactInputSingle, (p));
        payloads[1] = abi.encodeCall(Router.exactInputSingleWithPermit, (p, Router.Permit(0, 0, 0, 0)));
        payloads[2] = abi.encodeCall(Router.exactInput, (route));
        for (uint256 i; i < payloads.length; ++i) {
            token.configure(address(router), payloads[i]);
            vm.prank(taker);
            router.exactInputSingle(p);
            assertTrue(token.attempted());
            assertFalse(token.succeeded());
            assertEq(
                token.returnData(),
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            );
            assertEq(token.balanceOf(address(router)), 0);
        }
    }
}
