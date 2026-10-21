// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ConcentratedRangeBook as Book } from "../ConcentratedRangeBook.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { PeripheryPayments } from "./PeripheryPayments.sol";
import { LiquidityAmounts } from "./LiquidityAmounts.sol";

/// @notice ERC-721 ownership and wallet funding for persistent concentrated LP positions.
/// @dev NFT IDs equal core position IDs. Only positions minted here can be managed here.
///      No operator can act without NFT approval; every call settles its own tokens without sweeping donations.
contract RangeBookPositionManager is ERC721, PeripheryPayments {
    /// @notice Token budgets and principal protections for a new persistent LP position.
    struct MintParams {
        /// @notice Immutable market identifier, keccak256(abi.encode(Config)).
        bytes32 marketId;
        /// @notice Inclusive lower tick, aligned to the market spacing.
        int24 tickLower;
        /// @notice Exclusive upper tick, aligned to the market spacing.
        int24 tickUpper;
        /// @notice Maximum token0 principal atoms; unused ERC20 budget stays in the wallet.
        uint256 amount0Desired;
        /// @notice Maximum token1 principal atoms; unused ERC20 budget stays in the wallet.
        uint256 amount1Desired;
        /// @notice Minimum token0 principal atoms; accrued fees do not satisfy this bound.
        uint256 amount0Min;
        /// @notice Minimum token1 principal atoms; accrued fees do not satisfy this bound.
        uint256 amount1Min;
        /// @notice Initial NFT owner; zero, core and this manager are forbidden.
        address recipient;
        /// @notice Last permitted execution timestamp in Unix seconds; equality is allowed.
        uint64 deadline;
    }

    /// @notice Token budgets and principal protections for an owned or approved position.
    struct IncreaseLiquidityParams {
        /// @notice ERC721 token ID, equal to the underlying core position ID.
        uint256 tokenId;
        /// @notice Maximum token0 principal atoms; unused ERC20 budget stays in the wallet.
        uint256 amount0Desired;
        /// @notice Maximum token1 principal atoms; unused ERC20 budget stays in the wallet.
        uint256 amount1Desired;
        /// @notice Minimum token0 principal atoms; accrued fees do not satisfy this bound.
        uint256 amount0Min;
        /// @notice Minimum token1 principal atoms; accrued fees do not satisfy this bound.
        uint256 amount1Min;
        /// @notice Last permitted execution timestamp in Unix seconds; equality is allowed.
        uint64 deadline;
    }

    /// @notice Liquidity removal with immediate principal and fee delivery.
    struct DecreaseLiquidityParams {
        /// @notice ERC721 token ID, equal to the underlying core position ID.
        uint256 tokenId;
        /// @notice Positive concentrated-liquidity L to remove, not a token amount.
        uint128 liquidity;
        /// @notice Minimum token0 principal atoms; accrued fees do not satisfy this bound.
        uint256 amount0Min;
        /// @notice Minimum token1 principal atoms; accrued fees do not satisfy this bound.
        uint256 amount1Min;
        /// @notice Destination for withdrawn principal and fees; must be a valid external recipient.
        address recipient;
        /// @notice Last permitted execution timestamp in Unix seconds; equality is allowed.
        uint64 deadline;
        /// @notice Deliver the configured wrapped-native output as native currency.
        bool unwrapNative;
    }

    /// @notice Per-call balances and funded amounts used to isolate refunds from owner fees.
    struct Funding {
        /// @notice Market token0 address.
        address token0;
        /// @notice Market token1 address.
        address token1;
        /// @notice Contract token0 balance before this call; pre-existing funds are never refunded.
        uint256 before0;
        /// @notice Contract token1 balance before this call; pre-existing funds are never refunded.
        uint256 before1;
        /// @notice Token0 atoms funded by this call, including any refundable native budget.
        uint256 funded0;
        /// @notice Token1 atoms funded by this call, including any refundable native budget.
        uint256 funded1;
    }
    /// @notice Caller is neither the NFT owner nor an approved operator.
    error UnauthorizedPosition();
    /// @notice NFT cannot be destroyed while its core position has active liquidity.
    error PositionNotEmpty();
    /// @notice A position NFT was created for the corresponding core position.
    /// @param tokenId NFT and core position identifier.
    /// @param marketId Market receiving persistent AMM liquidity.
    /// @param recipient Initial NFT owner.
    /// @param liquidity Concentrated-liquidity L minted.
    event PositionMinted(
        uint256 indexed tokenId, bytes32 indexed marketId, address indexed recipient, uint128 liquidity
    );
    /// @notice Added liquidity and its gross token principal, excluding previously earned fees.
    /// @param tokenId NFT and core position identifier.
    /// @param liquidity Added L.
    /// @param amount0 Token0 principal atoms paid, excluding old fees.
    /// @param amount1 Token1 principal atoms paid, excluding old fees.
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Removed liquidity and principal; earned fees are reported separately.
    /// @param tokenId NFT and core position identifier.
    /// @param liquidity Removed L.
    /// @param amount0 Token0 principal atoms withdrawn, excluding fees.
    /// @param amount1 Token1 principal atoms withdrawn, excluding fees.
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Earned LP fees delivered to an authorized recipient, including during liquidity changes.
    /// @param tokenId NFT and core position identifier.
    /// @param recipient Recipient of fee proceeds.
    /// @param amount0 Token0 fee atoms paid.
    /// @param amount1 Token1 fee atoms paid.
    event Collect(uint256 indexed tokenId, address indexed recipient, uint256 amount0, uint256 amount1);

    /// @notice Deploys transferable ownership for newly minted positions on one core.
    /// @param book Trusted deployed exchange.
    /// @param wrapped WETH-compatible token, or zero to disable native payments.
    constructor(Book book, address wrapped) ERC721("RangeBook Positions", "RBP") PeripheryPayments(book, wrapped) { }

    /// @notice Creates a market if absent; identical configurations share the same deterministic ID.
    /// @param config Immutable market settings, including initial price.
    /// @return marketId keccak256(abi.encode(config)).
    function createAndInitializeMarketIfNecessary(Book.Config calldata config)
        external
        nonReentrant
        returns (bytes32 marketId)
    {
        marketId = keccak256(abi.encode(config));
        // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
        // slither-disable-next-line unused-return
        try core.getMarket(marketId) { }
        catch (bytes memory reason) {
            if (reason.length != 4 || bytes4(reason) != Book.UnknownMarket.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            marketId = core.createMarket(config);
        }
    }

    /// @notice Mints using desired budgets, pulling only computed ERC20 principal and refunding unused native input.
    /// @param p Aligned range, token budgets, principal minimums, recipient and deadline.
    /// @return tokenId New NFT and core position ID.
    /// @return liquidity Liquidity L actually minted.
    /// @return amount0 Actual token0 principal.
    /// @return amount1 Actual token1 principal.
    function mint(MintParams calldata p)
        external
        payable
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        _recipient(p.recipient);
        // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
        // slither-disable-next-line unused-return
        (Book.Config memory c, uint160 price,,) = core.getMarket(p.marketId);
        uint256 required0;
        uint256 required1;
        (liquidity, required0, required1) =
            LiquidityAmounts.forAmounts(price, p.tickLower, p.tickUpper, p.amount0Desired, p.amount1Desired);
        Funding memory f = _fund(c, p.amount0Desired, p.amount1Desired, required0, required1);
        bytes memory result = _execute(
            abi.encodeCall(
                Book.mint,
                (p.marketId, p.tickLower, p.tickUpper, liquidity, p.amount0Desired, p.amount1Desired, p.deadline)
            )
        );
        (tokenId, amount0, amount1) = abi.decode(result, (uint256, uint256, uint256));
        _minimums(amount0, amount1, p.amount0Min, p.amount1Min);
        _finishFunding(f, amount0, amount1, p.recipient, tokenId);
        _safeMint(p.recipient, tokenId);
        emit PositionMinted(tokenId, p.marketId, p.recipient, liquidity);
        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Adds liquidity from caller budgets; pre-existing position fees are paid to the NFT owner.
    /// @param p NFT ID, desired amounts, principal minimums and deadline.
    /// @return liquidity Added liquidity L.
    /// @return amount0 Token0 principal excluding fees.
    /// @return amount1 Token1 principal excluding fees.
    function increaseLiquidity(IncreaseLiquidityParams calldata p)
        external
        payable
        nonReentrant
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address owner = _authorized(p.tokenId);
        Book.Position memory position = core.getPosition(p.tokenId);
        // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
        // slither-disable-next-line unused-return
        (Book.Config memory c, uint160 price,,) = core.getMarket(position.marketId);
        uint256 required0;
        uint256 required1;
        (liquidity, required0, required1) =
            LiquidityAmounts.forAmounts(price, position.lower, position.upper, p.amount0Desired, p.amount1Desired);
        Funding memory f = _fund(c, p.amount0Desired, p.amount1Desired, required0, required1);
        (amount0, amount1) = abi.decode(
            _execute(
                abi.encodeCall(Book.increase, (p.tokenId, liquidity, p.amount0Desired, p.amount1Desired, p.deadline))
            ),
            (uint256, uint256)
        );
        _minimums(amount0, amount1, p.amount0Min, p.amount1Min);
        _finishFunding(f, amount0, amount1, owner, p.tokenId);
        emit IncreaseLiquidity(p.tokenId, liquidity, amount0, amount1);
    }

    /// @notice Removes liquidity and immediately delivers principal plus earned fees; no second collect is required.
    /// @param p NFT, liquidity, principal minimums, recipient, deadline and native-output preference.
    /// @return amount0 Token0 principal, excluding separately delivered fees.
    /// @return amount1 Token1 principal, excluding separately delivered fees.
    function decreaseLiquidity(DecreaseLiquidityParams calldata p)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _authorized(p.tokenId);
        _recipient(p.recipient);
        Funding memory f = _balances(p.tokenId, p.unwrapNative);
        (amount0, amount1) = abi.decode(
            _execute(abi.encodeCall(Book.burn, (p.tokenId, p.liquidity, p.amount0Min, p.amount1Min, p.deadline))),
            (uint256, uint256)
        );
        uint256 total0 = IERC20(f.token0).balanceOf(address(this)) - f.before0;
        uint256 total1 = IERC20(f.token1).balanceOf(address(this)) - f.before1;
        _pay(f.token0, p.recipient, total0, p.unwrapNative);
        _pay(f.token1, p.recipient, total1, p.unwrapNative);
        emit DecreaseLiquidity(p.tokenId, p.liquidity, amount0, amount1);
        emit Collect(p.tokenId, p.recipient, total0 - amount0, total1 - amount1);
    }

    /// @notice Delivers all whole accrued fees; recipient may differ from the authorized caller.
    /// @param tokenId Owned or approved NFT.
    /// @param recipient Fee destination.
    /// @param unwrapNative Whether the wrapped-native side should be delivered as native currency.
    /// @return amount0 Collected token0 atoms.
    /// @return amount1 Collected token1 atoms.
    function collect(uint256 tokenId, address recipient, bool unwrapNative)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _authorized(tokenId);
        _recipient(recipient);
        return _collect(tokenId, recipient, unwrapNative);
    }

    /// @notice Destroys an empty NFT after delivering residual whole fees to its owner.
    /// @param tokenId Owned or approved NFT with zero core liquidity.
    function burn(uint256 tokenId) external nonReentrant {
        address owner = _authorized(tokenId);
        if (core.getPosition(tokenId).accounting.liquidity != 0) revert PositionNotEmpty();
        _collect(tokenId, owner, false);
        _burn(tokenId);
    }

    /// @notice Returns core range/accounting for a live NFT; core owner is this manager, NFT owner is ownerOf(tokenId).
    /// @param tokenId Existing position NFT.
    /// @return position Core metadata and fee checkpoints.
    function positions(uint256 tokenId) external view returns (Book.Position memory position) {
        _requireOwned(tokenId);
        return core.getPosition(tokenId);
    }

    /// @notice Transfers ownership with the standard ERC-721 authorization checks; blocked during settlement callbacks.
    /// @param from Current NFT owner.
    /// @param to New owner.
    /// @param tokenId Position NFT.
    function transferFrom(address from, address to, uint256 tokenId) public override nonReentrant {
        super.transferFrom(from, to, tokenId);
    }

    /// @notice On-chain JSON metadata with the market, range and current liquidity.
    /// @param tokenId Existing position NFT.
    /// @return uri Base64 data URI; no external metadata host is required.
    function tokenURI(uint256 tokenId) public view override returns (string memory uri) {
        _requireOwned(tokenId);
        Book.Position memory p = core.getPosition(tokenId);
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"RangeBook Position #',
                        Strings.toString(tokenId),
                        '","description":"Persistent concentrated AMM liquidity",',
                        '"attributes":[{"trait_type":"market","value":"',
                        Strings.toHexString(uint256(p.marketId), 32),
                        '"},{"trait_type":"lowerTick","value":',
                        Strings.toStringSigned(p.lower),
                        '},{"trait_type":"upperTick","value":',
                        Strings.toStringSigned(p.upper),
                        '},{"trait_type":"liquidity","value":"',
                        Strings.toString(p.accounting.liquidity),
                        '"}]}'
                    )
                )
            )
        );
    }

    /// @dev Resolves current NFT ownership and requires owner, per-token approval or operator approval.
    function _authorized(uint256 id) private view returns (address owner) {
        owner = _requireOwned(id);
        if (!_isAuthorized(owner, msg.sender, id)) revert UnauthorizedPosition();
    }

    /// @dev Runs one core bookkeeping action and settles all resulting token deltas to this manager.
    function _execute(bytes memory action) private returns (bytes memory) {
        bytes[] memory actions = new bytes[](1);
        actions[0] = action;
        return core.executeWallet(actions, address(this))[0];
    }

    /// @dev Checks actual principal against both minima; historical fee payouts are excluded.
    function _minimums(uint256 a0, uint256 a1, uint256 min0, uint256 min1) private pure {
        if (a0 < min0 || a1 < min1) revert PeripherySlippage();
    }

    /// @dev Records donation baselines, funds required ERC20 principal or the declared native budget, and approves core.
    function _fund(Book.Config memory c, uint256 desired0, uint256 desired1, uint256 required0, uint256 required1)
        private
        returns (Funding memory f)
    {
        f = Funding(
            c.token0,
            c.token1,
            IERC20(c.token0).balanceOf(address(this)),
            IERC20(c.token1).balanceOf(address(this)),
            0,
            0
        );
        bool native0 = msg.value != 0 && c.token0 == wrappedNative;
        bool native1 = msg.value != 0 && c.token1 == wrappedNative;
        if (msg.value != 0) {
            if ((!native0 && !native1) || msg.value != (native0 ? desired0 : desired1)) revert InvalidNativeValue();
            _wrap(msg.value);
        }
        f.funded0 = native0 ? desired0 : required0;
        f.funded1 = native1 ? desired1 : required1;
        if (!native0) _pull(c.token0, required0);
        if (!native1) _pull(c.token1, required1);
        _approveCore(c.token0, required0);
        _approveCore(c.token1, required1);
    }

    /// @dev Returns unused funding to its payer and pays historical fees separately to the NFT owner.
    function _finishFunding(Funding memory f, uint256 used0, uint256 used1, address owner, uint256 id) private {
        uint256 refund0 = f.funded0 - used0;
        uint256 refund1 = f.funded1 - used1;
        uint256 fee0 = IERC20(f.token0).balanceOf(address(this)) - f.before0 - refund0;
        uint256 fee1 = IERC20(f.token1).balanceOf(address(this)) - f.before1 - refund1;
        _pay(f.token0, msg.sender, refund0, msg.value != 0);
        _pay(f.token1, msg.sender, refund1, msg.value != 0);
        _pay(f.token0, owner, fee0, false);
        _pay(f.token1, owner, fee1, false);
        if (fee0 != 0 || fee1 != 0) emit Collect(id, owner, fee0, fee1);
    }

    /// @dev Resolves position assets and records pre-call balances; validates native-output compatibility.
    function _balances(uint256 id, bool nativeOut) private view returns (Funding memory f) {
        // Only configuration/price or existence is needed here; active tick/liquidity are intentionally unused.
        // slither-disable-next-line unused-return
        (Book.Config memory c,,,) = core.getMarket(core.getPosition(id).marketId);
        if (nativeOut && (wrappedNative == address(0) || (c.token0 != wrappedNative && c.token1 != wrappedNative))) {
            revert InvalidNativeValue();
        }
        f = Funding(
            c.token0,
            c.token1,
            IERC20(c.token0).balanceOf(address(this)),
            IERC20(c.token1).balanceOf(address(this)),
            0,
            0
        );
    }

    /// @dev Collects whole core fees and pays only the returned amounts to the authorized recipient.
    function _collect(uint256 id, address recipient, bool nativeOut) private returns (uint256 a0, uint256 a1) {
        Funding memory f = _balances(id, nativeOut);
        (a0, a1) = abi.decode(_execute(abi.encodeCall(Book.collect, (id))), (uint256, uint256));
        _pay(f.token0, recipient, a0, nativeOut);
        _pay(f.token1, recipient, a1, nativeOut);
        emit Collect(id, recipient, a0, a1);
    }
}
