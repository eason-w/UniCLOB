// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LiquidityAmounts } from "../../src/periphery/LiquidityAmounts.sol";
import { SqrtPriceMath } from "../../src/vendor/uniswap/SqrtPriceMath.sol";
import { Vm } from "forge-std/Vm.sol";

import { ConcentratedBase, Book, MockERC20, TickMath, FeeMath } from "../concentrated/Base.sol";
import { RangeBookRouter as Router } from "../../src/periphery/RangeBookRouter.sol";
import { RangeBookQuoter as Quoter } from "../../src/periphery/RangeBookQuoter.sol";
import { RangeBookPositionManager as Manager } from "../../src/periphery/RangeBookPositionManager.sol";
import { ConcentratedRangeBookLens as Lens } from "../../src/periphery/RangeBookLens.sol";
import { PeripheryPayments } from "../../src/periphery/PeripheryPayments.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { CallbackToken, TaxToken } from "../mocks/HostileTokens.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract WrappedMock is MockERC20 {
    constructor() MockERC20("Wrapped", "WETH", 18) { }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{ value: amount }("");
        require(success);
    }
}

contract PermitMock is ERC20, ERC20Permit {
    constructor() ERC20("Permit", "PERM") ERC20Permit("Permit") { }

    function mint(address who, uint256 amount) external {
        _mint(who, amount);
    }
}

contract RejectNative {
    receive() external payable {
        revert("reject");
    }
}

contract ReceiverProbe is IERC721Receiver {
    Manager public manager;
    bool public blocked;

    constructor(Manager m) {
        manager = m;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        try manager.transferFrom(address(this), address(123), id) {
            blocked = false;
        } catch {
            blocked = true;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract NativeProbe {
    address public target;
    bytes public payload;
    bytes public failure;
    bool public armed;

    function configure(address t, bytes memory p) external {
        target = t;
        payload = p;
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            (bool ok, bytes memory data) = target.call(payload);
            require(!ok, "reentered");
            failure = data;
        }
    }
}

abstract contract PeripheryBase is ConcentratedBase {
    Router internal router;
    Quoter internal quoter;
    Manager internal manager;
    Lens internal lens;
    WrappedMock internal wrapped;

    function config() internal view override returns (Book.Config memory) {
        return Book.Config(address(token0), address(token1), LOT, 10, 500, 4, Q96);
    }

    function setUp() public virtual override {
        super.setUp();
        wrapped = new WrappedMock();
        vm.deal(address(wrapped), 1e40);
        router = new Router(book, address(wrapped));
        quoter = new Quoter(book);
        manager = new Manager(book, address(wrapped));
        lens = new Lens(book);
        for (uint256 i; i < 2; ++i) {
            address actor = i == 0 ? lp2 : taker;
            token0.mint(actor, 1e26);
            token1.mint(actor, 1e26);
            vm.startPrank(actor);
            token0.approve(address(router), type(uint256).max);
            token1.approve(address(router), type(uint256).max);
            token0.approve(address(manager), type(uint256).max);
            token1.approve(address(manager), type(uint256).max);
            vm.stopPrank();
        }
        full(lp, L);
    }

    function params(bool down, uint128 amount) internal view returns (Router.ExactInputSingleParams memory) {
        return Router.ExactInputSingleParams(
            market, down ? address(token0) : address(token1), taker, amount, 0, 0, 128, NEVER, true, false
        );
    }

    function mintParams(int24 low, int24 high) internal view returns (Manager.MintParams memory) {
        return Manager.MintParams(market, low, high, 1e20, 1e20, 0, 0, lp2, NEVER);
    }

    function nft() internal returns (uint256 id, uint128 liquidity) {
        vm.prank(lp2);
        (id, liquidity,,) = manager.mint(mintParams(-600, 600));
    }

    function stateHash() internal view returns (bytes32) {
        (Book.Config memory c, uint160 price, int24 tick, uint128 liquidity) = book.getMarket(market);
        (uint256 a, uint256 b, uint256 x, uint256 y) = book.reserves(market);
        return keccak256(
            abi.encode(
                c,
                price,
                tick,
                liquidity,
                a,
                b,
                x,
                y,
                book.protocolFees(address(token0)),
                book.protocolFees(address(token1)),
                book.totalLiability(address(token0)),
                book.totalLiability(address(token1))
            )
        );
    }
}

contract PeripheryTest is PeripheryBase {
    function testFuzz_QuoteMatchesHybridExecutionAndLeavesStateUntouched(bool down, uint96 raw) public {
        uint128 amount = uint128(bound(raw, 1e14, 1e23));
        order(!down, down ? int24(-10) : int24(10), 1000);
        Router.ExactInputSingleParams memory p = params(down, amount);
        bytes32 before_ = stateHash();
        Book.TradeResult memory expected = quoter.quoteExactInputSingle(p);
        assertEq(stateHash(), before_);
        vm.prank(taker);
        Book.TradeResult memory actual = router.exactInputSingle(p);
        assertEq(abi.encode(actual), abi.encode(expected));
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
        assertAccounting();
    }

    function test_QuoteRequiresNoFundingAndRevertsValidationExactly() public {
        Book.TradeRequest memory r = request(false, 1e18);
        vm.prank(address(0x123));
        Book.TradeResult memory result = quoter.quoteTrade(r);
        assertGt(result.output, 0);
        vm.expectRevert(abi.encodeWithSelector(Book.QuoteResult.selector, result));
        book.quoteTrade(r);
        r.minOutput = type(uint256).max;
        vm.expectRevert(Book.Slippage.selector);
        quoter.quoteTrade(r);
        r.minOutput = 0;
        r.deadline = 0;
        vm.warp(2);
        vm.expectRevert(Book.DeadlineExpired.selector);
        quoter.quoteTrade(r);
    }

    function test_PartialRefundCannotSweepDonationsAndStrictModeRollsBack() public {
        token1.mint(address(router), 123);
        Router.ExactInputSingleParams memory p = params(false, 1e23);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(10);
        uint256 before_ = token1.balanceOf(taker);
        p.allowPartial = false;
        bytes32 beforeState = stateHash();
        vm.prank(taker);
        vm.expectRevert(Book.IncompleteFill.selector);
        router.exactInputSingle(p);
        assertEq(stateHash(), beforeState);
        assertEq(token1.balanceOf(taker), before_);
        p.allowPartial = true;
        vm.prank(taker);
        Book.TradeResult memory r = router.exactInputSingle(p);
        assertLt(r.input, p.amountIn);
        assertEq(before_ - token1.balanceOf(taker), r.input);
        assertEq(token1.balanceOf(address(router)), 123);
    }

    function test_RouterRejectsWrongAssetRecipientAndUnexpectedNativeValue() public {
        Router.ExactInputSingleParams memory p = params(false, 1e18);
        p.tokenIn = address(wrapped);
        vm.expectRevert(Router.InvalidPath.selector);
        router.exactInputSingle(p);
        p = params(false, 1e18);
        p.recipient = address(router);
        vm.expectRevert(PeripheryPayments.InvalidAddress.selector);
        router.exactInputSingle(p);
        p = params(false, 1e18);
        vm.deal(taker, 1 ether);
        vm.prank(taker);
        vm.expectRevert(PeripheryPayments.InvalidNativeValue.selector);
        router.exactInputSingle{ value: 1 }(p);
        p.unwrapNative = true;
        vm.expectRevert(PeripheryPayments.InvalidNativeValue.selector);
        router.exactInputSingle(p);
    }

    function test_MultihopQuoteMatchesExecutionAndRevertsAllOnFinalSlippage() public {
        MockERC20 third = new MockERC20("Third", "C", 6);
        bytes32 second = book.createMarket(Book.Config(address(token0), address(third), LOT, 10, 500, 4, Q96));
        third.mint(lp, 1e35);
        vm.startPrank(lp);
        third.approve(address(book), type(uint256).max);
        book.deposit(address(third), 1e35, lp);
        book.mint(second, -887_270, 887_270, L, type(uint256).max, type(uint256).max, NEVER);
        vm.stopPrank();
        Router.Hop[] memory path = new Router.Hop[](2);
        path[0] = Router.Hop(market, address(token0), 0, 128);
        path[1] = Router.Hop(second, address(third), 0, 128);
        Router.ExactInputParams memory p = Router.ExactInputParams(address(token1), path, taker, 1e18, 0, NEVER, false);
        (uint256 expected, Book.TradeResult[] memory results) = quoter.quoteExactInput(p);
        assertEq(results.length, 2);
        p.amountOutMinimum = expected + 1;
        bytes32 before_ = stateHash();
        vm.prank(taker);
        vm.expectRevert(Book.Slippage.selector);
        router.exactInput(p);
        assertEq(stateHash(), before_);
        p.amountOutMinimum = expected;
        vm.prank(taker);
        assertEq(router.exactInput(p), expected);
        assertEq(third.balanceOf(taker), expected);
        assertEq(token0.balanceOf(address(router)), 0);
        p.path[1].marketId = market;
        vm.expectRevert(Quoter.InvalidPath.selector);
        quoter.quoteExactInput(p);
        vm.prank(taker);
        vm.expectRevert(Router.InvalidPath.selector);
        router.exactInput(p);
    }

    function testFuzz_ArbitraryLPRangeBudgetMintAndExit(uint16 width, uint96 raw) public {
        int24 half = int24(uint24(bound(width, 1, 65_000))) * 10;
        uint256 budget = bound(raw, 1e12, 1e24);
        Manager.MintParams memory p = mintParams(-half, half);
        p.amount0Desired = budget;
        p.amount1Desired = budget;
        (uint128 expected, uint256 used0, uint256 used1) =
            lens.quoteLiquidity(market, p.tickLower, p.tickUpper, budget, budget);
        uint256 before0 = token0.balanceOf(lp2);
        uint256 before1 = token1.balanceOf(lp2);
        vm.prank(lp2);
        (uint256 id, uint128 liquidity, uint256 a0, uint256 a1) = manager.mint(p);
        assertEq(liquidity, expected);
        assertEq(a0, used0);
        assertEq(a1, used1);
        assertEq(token0.balanceOf(lp2), before0 - a0);
        assertEq(token1.balanceOf(lp2), before1 - a1);
        assertEq(book.getPosition(id).owner, address(manager));
        assertEq(manager.ownerOf(id), lp2);
        vm.prank(lp2);
        manager.decreaseLiquidity(Manager.DecreaseLiquidityParams(id, liquidity, 0, 0, lp2, NEVER, false));
        vm.prank(lp2);
        manager.burn(id);
        assertEq(book.getPosition(id).accounting.liquidity, 0);
        assertEq(token0.balanceOf(address(manager)), 0);
        assertEq(token1.balanceOf(address(manager)), 0);
        assertAccounting();
    }

    function test_FullRangeAndOneSidedPositions() public {
        (int24 low, int24 high) = book.fullRange(market);
        vm.prank(lp2);
        (uint256 id,,,) = manager.mint(mintParams(low, high));
        Book.Position memory p = manager.positions(id);
        assertEq(p.lower, low);
        assertEq(p.upper, high);
        Manager.MintParams memory one = mintParams(100, 10_000);
        one.amount1Desired = 0;
        vm.prank(lp2);
        (,,, uint256 a1) = manager.mint(one);
        assertEq(a1, 0);
        assertGt(bytes(manager.tokenURI(id)).length, 100);
        assertTrue(manager.supportsInterface(0x80ac58cd));
    }

    function test_NFTTransferChangesWithdrawalAuthorityAndRevokesApproval() public {
        (uint256 id, uint128 liquidity) = nft();
        vm.prank(lp2);
        manager.approve(maker, id);
        vm.prank(maker);
        manager.transferFrom(lp2, taker, id);
        assertEq(manager.getApproved(id), address(0));
        vm.prank(lp2);
        vm.expectRevert(Manager.UnauthorizedPosition.selector);
        manager.collect(id, lp2, false);
        vm.prank(maker);
        vm.expectRevert(Manager.UnauthorizedPosition.selector);
        manager.collect(id, maker, false);
        vm.prank(taker);
        manager.decreaseLiquidity(Manager.DecreaseLiquidityParams(id, liquidity, 0, 0, taker, NEVER, false));
        vm.prank(taker);
        manager.burn(id);
    }

    function test_OperatorIncreasePaysHistoricalFeesToOwnerNotOperator() public {
        (uint256 id,) = nft();
        trade(false, 1e21);
        (,, uint256 fee0, uint256 fee1) = book.positionValue(id);
        assertGt(fee1, 0);
        vm.prank(lp2);
        manager.approve(taker, id);
        uint256 owner0 = token0.balanceOf(lp2);
        uint256 owner1 = token1.balanceOf(lp2);
        uint256 payer0 = token0.balanceOf(taker);
        uint256 payer1 = token1.balanceOf(taker);
        vm.prank(taker);
        (, uint256 used0, uint256 used1) =
            manager.increaseLiquidity(Manager.IncreaseLiquidityParams(id, 1e20, 1e20, 0, 0, NEVER));
        assertEq(token0.balanceOf(lp2), owner0 + fee0);
        assertEq(token1.balanceOf(lp2), owner1 + fee1);
        assertEq(token0.balanceOf(taker), payer0 - used0);
        assertEq(token1.balanceOf(taker), payer1 - used1);
        assertAccounting();
    }

    function test_LPMinsDeadlineAndUnapprovedAccessRollback() public {
        Manager.MintParams memory p = mintParams(-600, 600);
        p.amount0Min = 1e30;
        uint256 next = book.nextPositionId();
        uint256 before_ = token0.balanceOf(lp2);
        vm.prank(lp2);
        vm.expectRevert(PeripheryPayments.PeripherySlippage.selector);
        manager.mint(p);
        assertEq(book.nextPositionId(), next);
        assertEq(token0.balanceOf(lp2), before_);
        (uint256 id,) = nft();
        vm.prank(taker);
        vm.expectRevert(Manager.UnauthorizedPosition.selector);
        manager.increaseLiquidity(Manager.IncreaseLiquidityParams(id, 1e18, 1e18, 0, 0, NEVER));
        vm.prank(lp2);
        vm.expectRevert(Manager.PositionNotEmpty.selector);
        manager.burn(id);
        p = mintParams(-600, 600);
        p.deadline = 0;
        vm.warp(2);
        vm.prank(lp2);
        vm.expectRevert(Book.DeadlineExpired.selector);
        manager.mint(p);
    }

    function test_LPDonationsAreNeverSweptAndFeeCollectionIsIdempotent() public {
        token0.mint(address(manager), 17);
        token1.mint(address(manager), 31);
        (uint256 id,) = nft();
        trade(false, 1e20);
        vm.prank(lp2);
        (, uint256 fee) = manager.collect(id, lp2, false);
        assertGt(fee, 0);
        vm.prank(lp2);
        (uint256 a, uint256 b) = manager.collect(id, lp2, false);
        assertEq(a + b, 0);
        assertEq(token0.balanceOf(address(manager)), 17);
        assertEq(token1.balanceOf(address(manager)), 31);
    }

    function test_NFTReceiverCannotTransferDuringMintSettlement() public {
        ReceiverProbe recipient = new ReceiverProbe(manager);
        Manager.MintParams memory p = mintParams(-600, 600);
        p.recipient = address(recipient);
        vm.prank(lp2);
        (uint256 id,,,) = manager.mint(p);
        assertTrue(recipient.blocked());
        assertEq(manager.ownerOf(id), address(recipient));
    }

    function test_DepthPaginationAggregatesAndTracksPartialFills() public {
        order(true, 0, 100);
        order(true, 0, 200);
        order(true, 10, 75);
        order(true, 20, 50);
        (int24[] memory ticks, uint128[] memory lots) = lens.orderDepth(market, true, -887_272, 2);
        assertEq(ticks.length, 2);
        assertEq(ticks[0], 0);
        assertEq(lots[0], 300);
        assertEq(ticks[1], 10);
        (ticks, lots) = lens.orderDepth(market, true, ticks[1] + 1, 2);
        assertEq(ticks.length, 1);
        assertEq(ticks[0], 20);
        trade(false, uint128(FeeMath.gross(125 * LOT, 500)));
        (ticks, lots) = lens.orderDepth(market, true, 0, 128);
        assertEq(lots[0], 175);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        (, uint128[] memory remaining, uint128[] memory claimable) = lens.ordersById(ids);
        assertEq(remaining[0], 0);
        assertEq(claimable[0], 100);
        assertEq(remaining[1], 175);
        assertEq(claimable[1], 25);
        vm.expectRevert(Lens.InvalidQuery.selector);
        lens.orderDepth(market, true, 0, 129);
        vm.expectRevert(Lens.InvalidQuery.selector);
        lens.orderDepth(market, true, 0, 0);
    }

    function test_DescendingDepthNegativeUnalignedCursorAndEmptyPages() public {
        order(false, -10, 50);
        order(false, -30, 75);
        (int24[] memory ticks, uint128[] memory lots) = lens.orderDepth(market, false, -11, 128);
        assertEq(ticks.length, 1);
        assertEq(ticks[0], -30);
        assertEq(lots[0], 75);
        (ticks,) = lens.orderDepth(market, false, -31, 128);
        assertEq(ticks.length, 0);
    }

    function test_CreateMarketIfNecessaryIsIdempotent() public {
        assertEq(manager.createAndInitializeMarketIfNecessary(config()), market);
        Book.Config memory c = config();
        c.orderLot = 2 * LOT;
        bytes32 id = manager.createAndInitializeMarketIfNecessary(c);
        assertEq(id, keccak256(abi.encode(c)));
        assertEq(manager.createAndInitializeMarketIfNecessary(c), id);
    }

    function nativeMarket() internal returns (bytes32 id) {
        id = book.createMarket(Book.Config(address(wrapped), address(token1), LOT, 10, 500, 4, Q96));
        wrapped.mint(lp, 1e30);
        vm.startPrank(lp);
        wrapped.approve(address(book), type(uint256).max);
        book.deposit(address(wrapped), 1e30, lp);
        book.mint(id, -887_270, 887_270, L, type(uint256).max, type(uint256).max, NEVER);
        vm.stopPrank();
    }

    function test_NativeSwapRefundAndOutputUnwrap() public {
        bytes32 id = nativeMarket();
        vm.deal(taker, 100 ether);
        Router.ExactInputSingleParams memory p = params(true, 1e18);
        p.marketId = id;
        p.tokenIn = address(wrapped);
        uint256 before_ = taker.balance;
        vm.prank(taker);
        Book.TradeResult memory first = router.exactInputSingle{ value: 1e18 }(p);
        assertEq(taker.balance, before_ - first.input);
        assertEq(address(router).balance, 0);
        p.tokenIn = address(token1);
        p.unwrapNative = true;
        vm.prank(taker);
        Book.TradeResult memory second = router.exactInputSingle(p);
        assertEq(taker.balance, before_ - first.input + second.output);
        assertEq(wrapped.balanceOf(address(router)), 0);
    }

    function test_NativeLPRefundIncreaseAndExit() public {
        bytes32 id = nativeMarket();
        vm.deal(lp2, 1000 ether);
        Manager.MintParams memory p = mintParams(100, 10_000);
        p.marketId = id;
        p.amount0Desired = 1 ether;
        p.amount1Desired = 0;
        uint256 before_ = lp2.balance;
        vm.prank(lp2);
        (uint256 position, uint128 liquidity, uint256 a0,) = manager.mint{ value: 1 ether }(p);
        assertEq(lp2.balance, before_ - a0);
        vm.prank(lp2);
        (uint128 added,,) = manager.increaseLiquidity{ value: 1 ether }(
            Manager.IncreaseLiquidityParams(position, 1 ether, 0, 0, 0, NEVER)
        );
        vm.prank(lp2);
        manager.decreaseLiquidity(Manager.DecreaseLiquidityParams(position, liquidity + added, 0, 0, lp2, NEVER, true));
        assertEq(wrapped.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
    }

    function test_NativeRejectionRollsBackSwap() public {
        bytes32 id = nativeMarket();
        RejectNative recipient = new RejectNative();
        Router.ExactInputSingleParams memory p = params(false, 1e18);
        p.marketId = id;
        p.recipient = address(recipient);
        p.unwrapNative = true;
        (, uint160 before_,,) = book.getMarket(id);
        uint256 funds = token1.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(PeripheryPayments.NativeTransferFailed.selector);
        router.exactInputSingle(p);
        (, uint160 after_,,) = book.getMarket(id);
        assertEq(after_, before_);
        assertEq(token1.balanceOf(taker), funds);
    }

    function test_TokenCallbackCannotReenterRouterOrManager() public {
        CallbackToken token = new CallbackToken();
        bytes32 id = book.createMarket(Book.Config(address(token), address(token1), LOT, 10, 500, 4, Q96));
        token.mint(lp2, 1e26);
        vm.prank(lp2);
        token.approve(address(manager), type(uint256).max);
        Manager.MintParams memory p = mintParams(-600, 600);
        p.marketId = id;
        token.configure(address(manager), abi.encodeCall(Manager.mint, (p)));
        vm.prank(lp2);
        manager.mint(p);
        assertTrue(token.attempted());
        assertFalse(token.succeeded());
        assertEq(
            token.returnData(), abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        token.mint(taker, 1e20);
        vm.prank(taker);
        token.approve(address(router), type(uint256).max);
        Router.ExactInputSingleParams memory r = params(true, 1e18);
        r.marketId = id;
        r.tokenIn = address(token);
        token.configure(address(router), abi.encodeCall(Router.exactInputSingle, (r)));
        vm.prank(taker);
        router.exactInputSingle(r);
        assertTrue(token.attempted());
        assertFalse(token.succeeded());
        assertEq(
            token.returnData(), abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_TaxedInputFailsWithoutTakingDonations() public {
        TaxToken tax = new TaxToken();
        bytes32 id = book.createMarket(Book.Config(address(tax), address(token1), LOT, 10, 500, 4, Q96));
        tax.mint(lp2, 1e22);
        vm.prank(lp2);
        tax.approve(address(manager), type(uint256).max);
        tax.mint(address(manager), 99);
        tax.setTax(true);
        Manager.MintParams memory p = mintParams(-600, 600);
        p.marketId = id;
        vm.prank(lp2);
        vm.expectRevert(PeripheryPayments.UnsupportedAsset.selector);
        manager.mint(p);
        assertEq(tax.balanceOf(address(manager)), 99);
        assertEq(tax.balanceOf(lp2), 1e22);
    }

    function test_PermitSwapAndAlreadyUsedPermitFallback() public {
        PermitMock token = new PermitMock();
        bytes32 id = book.createMarket(Book.Config(address(token), address(token1), LOT, 10, 500, 4, Q96));
        token.mint(lp, 1e30);
        vm.startPrank(lp);
        token.approve(address(book), type(uint256).max);
        book.deposit(address(token), 1e30, lp);
        book.mint(id, -887_270, 887_270, L, type(uint256).max, type(uint256).max, NEVER);
        vm.stopPrank();
        uint256 key = 1234;
        address signer = vm.addr(key);
        token.mint(signer, 1e20);
        Router.ExactInputSingleParams memory p = params(true, 1e18);
        p.marketId = id;
        p.tokenIn = address(token);
        p.recipient = signer;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(router),
                p.amountIn,
                token.nonces(signer),
                uint256(NEVER)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
        token.permit(signer, address(router), p.amountIn, NEVER, v, r, s); // relayer front-runs only the permit
        vm.prank(signer);
        router.exactInputSingleWithPermit(p, Router.Permit(NEVER, v, r, s));
        assertEq(token.nonces(signer), 1);
        vm.prank(signer);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(router), 0, p.amountIn
            )
        );
        router.exactInputSingleWithPermit(p, Router.Permit(NEVER, v, r, s));
    }

    function test_QuoteTraversesAMMOrderAMMAndRollsBackClaims() public {
        uint256 id = order(true, 10, 1000);
        Router.ExactInputSingleParams memory p = params(false, 1e22);
        bytes32 before_ = stateHash();
        Book.TradeResult memory expected = quoter.quoteExactInputSingle(p);
        assertGt(expected.ammInput, 0);
        assertGt(expected.orderInput, 0);
        assertEq(stateHash(), before_);
        (, uint128 remaining, uint128 claimable) = book.getOrder(id);
        assertEq(remaining, 1000);
        assertEq(claimable, 0);
        vm.prank(taker);
        Book.TradeResult memory actual = router.exactInputSingle(p);
        assertEq(abi.encode(actual), abi.encode(expected));
        (, remaining, claimable) = book.getOrder(id);
        assertEq(remaining, 0);
        assertEq(claimable, 1000);
    }

    function test_NativePartialRefundPreservesForcedEthAndBlocksCallbackReentry() public {
        bytes32 id = nativeMarket();
        vm.deal(taker, 1e24);
        vm.deal(address(router), 17);
        Router.ExactInputSingleParams memory p = params(true, 1e22);
        p.marketId = id;
        p.tokenIn = address(wrapped);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-10);
        uint256 before_ = taker.balance;
        vm.prank(taker);
        Book.TradeResult memory r = router.exactInputSingle{ value: 1e22 }(p);
        assertLt(r.input, p.amountIn);
        assertEq(taker.balance, before_ - r.input);
        assertEq(address(router).balance, 17);
        NativeProbe probe = new NativeProbe();
        p = params(false, 1e18);
        p.marketId = id;
        p.unwrapNative = true;
        p.recipient = address(probe);
        probe.configure(address(router), abi.encodeCall(Router.exactInputSingle, (p)));
        vm.prank(taker);
        router.exactInputSingle(p);
        assertEq(
            probe.failure(), abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(router).balance, 17);
    }

    function test_TransferredNFTIncludesPreviouslyEarnedFees() public {
        (uint256 id,) = nft();
        trade(false, 1e21);
        (,, uint256 f0, uint256 f1) = book.positionValue(id);
        assertGt(f1, 0);
        vm.prank(lp2);
        manager.transferFrom(lp2, taker, id);
        uint256 before_ = token1.balanceOf(taker);
        vm.prank(taker);
        (uint256 a0, uint256 a1) = manager.collect(id, taker, false);
        assertEq(a0, f0);
        assertEq(a1, f1);
        assertEq(token1.balanceOf(taker), before_ + f1);
    }

    function test_RouterAndManagerEventsAttributeTheActualUser() public {
        vm.recordLogs();
        vm.prank(taker);
        Book.TradeResult memory result = router.exactInputSingle(params(false, 1e18));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 signature = keccak256("SwapExecuted(address,address,bytes32,address,address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == signature) {
                found = true;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(taker))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(taker))));
                (address input, address output, uint256 spent, uint256 received) =
                    abi.decode(logs[i].data, (address, address, uint256, uint256));
                assertEq(input, address(token1));
                assertEq(output, address(token0));
                assertEq(spent, result.input);
                assertEq(received, result.output);
            }
        }
        assertTrue(found);
        vm.recordLogs();
        (uint256 id,) = nft();
        logs = vm.getRecordedLogs();
        found = false;
        signature = keccak256("PositionMinted(uint256,bytes32,address,uint128)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == signature) {
                found = true;
                assertEq(logs[i].topics[1], bytes32(id));
                assertEq(logs[i].topics[2], market);
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(lp2))));
            }
        }
        assertTrue(found);
    }

    function test_LPOnlyPullsRequiredPrincipalNotTheWholeBudget() public {
        Manager.MintParams memory p = mintParams(-600, 600);
        p.amount0Desired = 1e23;
        p.amount1Desired = 1e18;
        (, uint256 needed0, uint256 needed1) =
            lens.quoteLiquidity(market, p.tickLower, p.tickUpper, p.amount0Desired, p.amount1Desired);
        assertLt(needed0, p.amount0Desired);
        vm.startPrank(lp2);
        token0.approve(address(manager), needed0);
        token1.approve(address(manager), needed1);
        (,, uint256 used0, uint256 used1) = manager.mint(p);
        vm.stopPrank();
        assertEq(used0, needed0);
        assertEq(used1, needed1);
        assertEq(token0.allowance(lp2, address(manager)), 0);
        assertEq(token1.allowance(lp2, address(manager)), 0);
    }

    function test_NativeFundingWorksWhenWrappedAssetIsToken1() public {
        bytes32 id = book.createMarket(Book.Config(address(token0), address(wrapped), LOT, 10, 500, 4, Q96));
        Manager.MintParams memory p = mintParams(-600, 600);
        p.marketId = id;
        p.amount1Desired = 1 ether;
        vm.deal(lp2, 100 ether);
        uint256 before_ = lp2.balance;
        vm.prank(lp2);
        (uint256 position, uint128 liquidity,, uint256 a1) = manager.mint{ value: 1 ether }(p);
        assertEq(lp2.balance, before_ - a1);
        vm.prank(lp2);
        manager.decreaseLiquidity(Manager.DecreaseLiquidityParams(position, liquidity, 0, 0, lp2, NEVER, true));
        assertEq(wrapped.balanceOf(address(manager)), 0);
    }

    function testFuzz_LiquidityBudgetInverseAcrossFullTickDomain(
        int24 rawLower,
        uint24 width,
        int24 rawPrice,
        uint64 rawL
    ) public pure {
        int24 lower = int24(bound(rawLower, -887_272, 887_271));
        int24 upper = lower + int24(uint24(bound(width, 1, uint24(887_272 - lower))));
        uint160 price = TickMath.getSqrtPriceAtTick(int24(bound(rawPrice, -887_271, 887_271)));
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint128 original = uint128(bound(rawL, 1, 1e18));
        (uint256 budget0, uint256 budget1) = _principal(price, a, b, original);
        (uint128 result, uint256 required0, uint256 required1) =
            LiquidityAmounts.forAmounts(price, lower, upper, budget0, budget1);
        assertGe(result, original);
        assertLe(required0, budget0);
        assertLe(required1, budget1);
        (uint256 next0, uint256 next1) = _principal(price, a, b, result + 1);
        assertTrue(next0 > budget0 || next1 > budget1, "liquidity was not maximal for the supplied budgets");
    }

    function test_LowPriceToken0BudgetDoesNotRoundLiquidityToZero() public pure {
        uint160 price = TickMath.getSqrtPriceAtTick(-800_000);
        uint160 a = TickMath.getSqrtPriceAtTick(-700_000);
        uint160 b = TickMath.getSqrtPriceAtTick(-699_000);
        uint256 budget = SqrtPriceMath.getAmount0Delta(a, b, 1e18, true);
        (uint128 liquidity, uint256 used0, uint256 used1) =
            LiquidityAmounts.forAmounts(price, -700_000, -699_000, budget, 0);
        assertGe(liquidity, 1e18);
        assertLe(used0, budget);
        assertEq(used1, 0);
    }

    function _principal(uint160 price, uint160 a, uint160 b, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (price < b) amount0 = SqrtPriceMath.getAmount0Delta(price < a ? a : price, b, liquidity, true);
        if (price > a) amount1 = SqrtPriceMath.getAmount1Delta(a, price > b ? b : price, liquidity, true);
    }
}
