// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PeripheryBase, Book, Router, Manager, MockERC20, PermitMock } from "./Periphery.t.sol";
import { TickMath } from "../../src/vendor/uniswap/TickMath.sol";
import { ConcentratedLiquidity } from "../../src/libraries/ConcentratedLiquidity.sol";
import { OrderBookAccounting } from "../../src/libraries/OrderBookAccounting.sol";
import { WalletSettlement } from "../../src/libraries/WalletSettlement.sol";

/// @notice Additional cold, committed-state workflow benchmarks, including matched direct-core alternatives.
contract PeripheryExtendedGasTest is PeripheryBase {
    bytes32 internal nativeId;
    bytes32 internal permitId;
    uint256 internal emptyFeePosition;
    uint256 internal nativePosition;
    uint128 internal nativeLiquidity;
    PermitMock internal permitToken;
    address internal signer;
    Router.Permit internal permit;

    function setUp() public override {
        super.setUp();
        (emptyFeePosition,) = nft();
        nativeId = _pool(wrapped, token0);
        permitToken = new PermitMock();
        permitId = _pool(MockERC20(address(permitToken)), token0);
        vm.deal(taker, 1000 ether);
        vm.deal(lp2, 1000 ether);
        vm.prank(taker);
        router.exactInputSingle(params(false, 1e18)); // establish router approval and fee histories
        // Keep a separate position whose fee history remains empty.
        Manager.MintParams memory m = mintParams(-1000, 1000);
        m.marketId = nativeId;
        m.amount0Desired = 1 ether;
        vm.prank(lp2);
        (nativePosition, nativeLiquidity,,) = manager.mint{ value: 1 ether }(m);
        signer = vm.addr(1234);
        permitToken.mint(signer, 10 ether);
        token0.mint(signer, 1); // established output balance
        bytes32 hash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(router),
                uint256(1 ether),
                uint256(0),
                uint256(NEVER)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(1234, keccak256(abi.encodePacked("\x19\x01", permitToken.DOMAIN_SEPARATOR(), hash)));
        permit = Router.Permit(NEVER, v, r, s);
        for (int24 tick = 10; tick <= 160; tick += 10) {
            order(true, tick, 100);
        }
    }

    function _pool(MockERC20 a, MockERC20 b) private returns (bytes32 id) {
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

    function _cool() private {
        vm.cool(address(book));
        vm.cool(address(router));
        vm.cool(address(manager));
        vm.cool(address(quoter));
        vm.cool(address(lens));
        vm.cool(address(token0));
        vm.cool(address(token1));
        vm.cool(address(wrapped));
        vm.cool(address(permitToken));
        vm.cool(address(ConcentratedLiquidity));
        vm.cool(address(OrderBookAccounting));
        vm.cool(address(WalletSettlement));
    }

    function test_Gas_MatchedDirectSwap() public {
        Book.TradeRequest memory p = request(false, 1e18);
        _cool();
        vm.prank(taker);
        Book.TradeResult memory result = book.swapWallet(p, taker);
        vm.snapshotGasLastCall("PeripheryExtended", "matched_direct_swap");
        assertGt(result.output, 0);
    }

    function test_Gas_MatchedRouterSwap() public {
        Router.ExactInputSingleParams memory p = params(false, 1e18);
        _cool();
        vm.prank(taker);
        Book.TradeResult memory result = router.exactInputSingle(p);
        vm.snapshotGasLastCall("PeripheryExtended", "matched_router_swap");
        assertGt(result.output, 0);
    }

    function test_Gas_MatchedDirectMint() public {
        Manager.MintParams memory p = mintParams(-6000, 6000);
        (uint128 liquidity,,) =
            lens.quoteLiquidity(market, p.tickLower, p.tickUpper, p.amount0Desired, p.amount1Desired);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            Book.mint, (market, p.tickLower, p.tickUpper, liquidity, p.amount0Desired, p.amount1Desired, NEVER)
        );
        _cool();
        vm.prank(lp2);
        book.executeWallet(calls, lp2);
        vm.snapshotGasLastCall("PeripheryExtended", "matched_direct_wallet_mint");
    }

    function test_Gas_MatchedNFTMint() public {
        Manager.MintParams memory p = mintParams(-6000, 6000);
        _cool();
        vm.prank(lp2);
        manager.mint(p);
        vm.snapshotGasLastCall("PeripheryExtended", "matched_nft_mint");
    }

    function test_Gas_NFTMintToken0Only() public {
        Manager.MintParams memory p = mintParams(1000, 10_000);
        p.amount1Desired = 0;
        _cool();
        vm.prank(lp2);
        (,,, uint256 used1) = manager.mint(p);
        vm.snapshotGasLastCall("PeripheryExtended", "nft_mint_token0_only");
        assertEq(used1, 0);
    }

    function test_Gas_NFTMintToken1Only() public {
        Manager.MintParams memory p = mintParams(-10_000, -1000);
        p.amount0Desired = 0;
        _cool();
        vm.prank(lp2);
        (,, uint256 used0,) = manager.mint(p);
        vm.snapshotGasLastCall("PeripheryExtended", "nft_mint_token1_only");
        assertEq(used0, 0);
    }

    function test_Gas_RouterPartialRefund() public {
        Router.ExactInputSingleParams memory p = params(false, 1e23);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(10);
        _cool();
        vm.prank(taker);
        Book.TradeResult memory r = router.exactInputSingle(p);
        vm.snapshotGasLastCall("PeripheryExtended", "router_partial_refund");
        assertLt(r.input, p.amountIn);
    }

    function test_Gas_RouterHybridSweep16Levels() public {
        Router.ExactInputSingleParams memory p = params(false, 1e23);
        _cool();
        vm.prank(taker);
        Book.TradeResult memory r = router.exactInputSingle(p);
        vm.snapshotGasLastCall("PeripheryExtended", "router_hybrid_sweep_16_levels");
        assertGt(r.ammInput, 0);
        assertGt(r.orderInput, 0);
        (bool found,) = book.bestOrder(market, true);
        assertFalse(found);
    }

    function test_Gas_RouterNativeInput() public {
        Router.ExactInputSingleParams memory p = params(true, 1 ether);
        p.marketId = nativeId;
        p.tokenIn = address(wrapped);
        _cool();
        vm.prank(taker);
        router.exactInputSingle{ value: 1 ether }(p);
        vm.snapshotGasLastCall("PeripheryExtended", "router_native_input_first_approval");
    }

    function test_Gas_RouterNativeOutput() public {
        Router.ExactInputSingleParams memory p = params(false, 1 ether);
        p.marketId = nativeId;
        p.tokenIn = address(token0);
        p.unwrapNative = true;
        _cool();
        vm.prank(taker);
        router.exactInputSingle(p);
        vm.snapshotGasLastCall("PeripheryExtended", "router_native_output_first_approval");
    }

    function test_Gas_RouterPermit() public {
        Router.ExactInputSingleParams memory p = params(true, 1 ether);
        p.marketId = permitId;
        p.tokenIn = address(permitToken);
        p.recipient = signer;
        Router.Permit memory signature = permit;
        _cool();
        vm.prank(signer);
        router.exactInputSingleWithPermit(p, signature);
        vm.snapshotGasLastCall("PeripheryExtended", "router_permit_first_approval");
    }

    function test_Gas_NFTNativeMint() public {
        Manager.MintParams memory p = mintParams(-6000, 6000);
        p.marketId = nativeId;
        p.amount0Desired = 1 ether;
        _cool();
        vm.prank(lp2);
        manager.mint{ value: 1 ether }(p);
        vm.snapshotGasLastCall("PeripheryExtended", "nft_native_mint");
    }

    function test_Gas_NFTNativeExit() public {
        Manager.DecreaseLiquidityParams memory p =
            Manager.DecreaseLiquidityParams(nativePosition, nativeLiquidity, 0, 0, lp2, NEVER, true);
        _cool();
        vm.prank(lp2);
        manager.decreaseLiquidity(p);
        vm.snapshotGasLastCall("PeripheryExtended", "nft_native_exit");
    }

    function test_Gas_NFTEmptyCollect() public {
        _cool();
        vm.prank(lp2);
        (uint256 a0, uint256 a1) = manager.collect(nativePosition, lp2, false);
        vm.snapshotGasLastCall("PeripheryExtended", "nft_empty_collect");
        assertEq(a0 + a1, 0);
    }
}
