// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Standalone ABI for RangeBookPositionManager.
interface IRangeBookPositionManager {
    struct Config {
        /// @notice Base asset address; token order is not automatically sorted.
        address token0;
        /// @notice Quote asset address; price is token1 atoms per token0 atom.
        address token1;
        /// @notice Token0 atoms per ordinary-order lot; independent of AMM liquidity units.
        uint128 orderLot;
        /// @notice Positive grid spacing for LP endpoints and ordinary-order prices.
        int24 tickSpacing;
        /// @notice Uniform gross-input taker fee in parts per million.
        uint24 feePpm;
        /// @notice AMM fee share denominator: protocol receives 1/divisor with carried rounding; order fees go entirely to protocol.
        uint8 protocolDivisor;
        /// @notice Initial Q64.96 square-root price; part of immutable market identity.
        uint160 initialSqrtPriceX96;
    }

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

    struct Position {
        /// @notice Immutable market identifier, keccak256(abi.encode(Config)).
        bytes32 marketId;
        /// @notice Core owner; for NFT positions this is the position-manager contract.
        address owner;
        /// @notice Inclusive lower tick.
        int24 lower;
        /// @notice Exclusive upper tick.
        int24 upper;
        /// @notice Liquidity and fee-growth checkpoints for this persistent range.
        LiquidityPosition accounting;
    }

    struct LiquidityPosition {
        uint128 liquidity;
        uint128 fraction0;
        uint128 fraction1;
        uint256 last0;
        uint256 last1;
    }

    /// @notice See {IERC721-approve}.
    /// @param to NFT recipient or account to approve, as defined by this operation.
    /// @param tokenId ERC721 position identifier.
    function approve(address to, uint256 tokenId) external;

    /// @notice See {IERC721-balanceOf}.
    /// @param owner Account whose balance or authorization is queried.
    /// @return arg0 See {IERC721-balanceOf}.
    function balanceOf(address owner) external view returns (uint256 arg0);

    /// @notice Destroys an empty NFT after delivering residual whole fees to its owner.
    /// @param tokenId Owned or approved NFT with zero core liquidity.
    function burn(uint256 tokenId) external;

    /// @notice Delivers all whole accrued fees; recipient may differ from the authorized caller.
    /// @param tokenId Owned or approved NFT.
    /// @param recipient Fee destination.
    /// @param unwrapNative Whether the wrapped-native side should be delivered as native currency.
    /// @return amount0 Collected token0 atoms.
    /// @return amount1 Collected token1 atoms.
    function collect(uint256 tokenId, address recipient, bool unwrapNative)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Immutable trusted exchange used for all operations.
    /// @return arg0 Immutable trusted exchange used for all operations.
    function core() external view returns (address arg0);

    /// @notice Creates a market if absent; identical configurations share the same deterministic ID.
    /// @param config Immutable market settings, including initial price.
    /// @return marketId keccak256(abi.encode(config)).
    function createAndInitializeMarketIfNecessary(Config calldata config) external returns (bytes32 marketId);

    /// @notice Removes liquidity and immediately delivers principal plus earned fees; no second collect is required.
    /// @param p NFT, liquidity, principal minimums, recipient, deadline and native-output preference.
    /// @return amount0 Token0 principal, excluding separately delivered fees.
    /// @return amount1 Token1 principal, excluding separately delivered fees.
    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external returns (uint256 amount0, uint256 amount1);

    /// @notice See {IERC721-getApproved}.
    /// @param tokenId ERC721 position identifier.
    /// @return arg0 See {IERC721-getApproved}.
    function getApproved(uint256 tokenId) external view returns (address arg0);

    /// @notice Adds liquidity from caller budgets; pre-existing position fees are paid to the NFT owner.
    /// @param p NFT ID, desired amounts, principal minimums and deadline.
    /// @return liquidity Token0 principal excluding fees.
    /// @return amount0 Token1 principal excluding fees.
    /// @return amount1 Added liquidity L.
    function increaseLiquidity(IncreaseLiquidityParams calldata p)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice See {IERC721-isApprovedForAll}.
    /// @param owner Account whose balance or authorization is queried.
    /// @param operator Account to authorize for all caller NFTs.
    /// @return arg0 See {IERC721-isApprovedForAll}.
    function isApprovedForAll(address owner, address operator) external view returns (bool arg0);

    /// @notice Mints using desired budgets, pulling only computed ERC20 principal and refunding unused native input.
    /// @param p Aligned range, token budgets, principal minimums, recipient and deadline.
    /// @return tokenId Actual token0 principal.
    /// @return liquidity Actual token1 principal.
    /// @return amount0 Liquidity L actually minted.
    /// @return amount1 New NFT and core position ID.
    function mint(MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice See {IERC721Metadata-name}.
    /// @return arg0 See {IERC721Metadata-name}.
    function name() external view returns (string memory arg0);

    /// @notice See {IERC721-ownerOf}.
    /// @param tokenId ERC721 position identifier.
    /// @return arg0 See {IERC721-ownerOf}.
    function ownerOf(uint256 tokenId) external view returns (address arg0);

    /// @notice Returns core range/accounting for a live NFT; core owner is this manager, NFT owner is ownerOf(tokenId).
    /// @param tokenId Existing position NFT.
    /// @return position Core metadata and fee checkpoints.
    function positions(uint256 tokenId) external view returns (Position memory position);

    /// @notice See {IERC721-safeTransferFrom}.
    /// @param from Current NFT owner.
    /// @param to NFT recipient or account to approve, as defined by this operation.
    /// @param tokenId ERC721 position identifier.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice See {IERC721-safeTransferFrom}.
    /// @param from Current NFT owner.
    /// @param to NFT recipient or account to approve, as defined by this operation.
    /// @param tokenId ERC721 position identifier.
    /// @param data Bytes forwarded to the NFT receiver callback.
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;

    /// @notice See {IERC721-setApprovalForAll}.
    /// @param operator Account to authorize for all caller NFTs.
    /// @param approved Whether operator authorization is enabled.
    function setApprovalForAll(address operator, bool approved) external;

    /// @notice See {IERC165-supportsInterface}.
    /// @param interfaceId ERC165 interface identifier to query.
    /// @return arg0 See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) external view returns (bool arg0);

    /// @notice See {IERC721Metadata-symbol}.
    /// @return arg0 See {IERC721Metadata-symbol}.
    function symbol() external view returns (string memory arg0);

    /// @notice On-chain JSON metadata with the market, range and current liquidity.
    /// @param tokenId Existing position NFT.
    /// @return uri Base64 data URI; no external metadata host is required.
    function tokenURI(uint256 tokenId) external view returns (string memory uri);

    /// @notice Transfers ownership with the standard ERC-721 authorization checks; blocked during settlement callbacks.
    /// @param from Current NFT owner.
    /// @param to New owner.
    /// @param tokenId Position NFT.
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Immutable trusted wrapped-native asset; address zero disables native payment support.
    /// @return arg0 Immutable trusted wrapped-native asset; address zero disables native payment support.
    function wrappedNative() external view returns (address arg0);

    /// @notice Emitted when the allowance of a `spender` for an `owner` is set by
    /// a call to {approve}. `value` is the new allowance.
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /// @notice Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// @notice Earned LP fees delivered to an authorized recipient, including during liquidity changes.
    /// @param tokenId NFT and core position identifier.
    /// @param recipient Recipient of fee proceeds.
    /// @param amount0 Token0 fee atoms paid.
    /// @param amount1 Token1 fee atoms paid.
    event Collect(uint256 indexed tokenId, address indexed recipient, uint256 amount0, uint256 amount1);

    /// @notice Removed liquidity and principal; earned fees are reported separately.
    /// @param tokenId NFT and core position identifier.
    /// @param liquidity Removed L.
    /// @param amount0 Token0 principal atoms withdrawn, excluding fees.
    /// @param amount1 Token1 principal atoms withdrawn, excluding fees.
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Added liquidity and its gross token principal, excluding previously earned fees.
    /// @param tokenId NFT and core position identifier.
    /// @param liquidity Added L.
    /// @param amount0 Token0 principal atoms paid, excluding old fees.
    /// @param amount1 Token1 principal atoms paid, excluding old fees.
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice A position NFT was created for the corresponding core position.
    /// @param tokenId NFT and core position identifier.
    /// @param marketId Market receiving persistent AMM liquidity.
    /// @param recipient Initial NFT owner.
    /// @param liquidity Concentrated-liquidity L minted.
    event PositionMinted(
        uint256 indexed tokenId, bytes32 indexed marketId, address indexed recipient, uint128 liquidity
    );

    /// @notice Emitted when `value` tokens are moved from one account (`from`) to
    /// another (`to`).
    /// Note that `value` may be zero.
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /// @notice Indicates an error related to the ownership over a particular token. Used in transfers.
    /// @param sender Address whose tokens are being transferred.
    /// @param tokenId Identifier number of a token.
    /// @param owner Address of the current owner of a token.
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /// @notice Indicates a failure with the `operator`’s approval. Used in transfers.
    /// @param operator Address that may be allowed to operate on tokens without being their owner.
    /// @param tokenId Identifier number of a token.
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /// @notice Indicates a failure with the `approver` of a token to be approved. Used in approvals.
    /// @param approver Address initiating an approval operation.
    error ERC721InvalidApprover(address approver);

    /// @notice Indicates a failure with the `operator` to be approved. Used in approvals.
    /// @param operator Address that may be allowed to operate on tokens without being their owner.
    error ERC721InvalidOperator(address operator);

    /// @notice Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in ERC-20.
    /// Used in balance queries.
    /// @param owner Address of the current owner of a token.
    error ERC721InvalidOwner(address owner);

    /// @notice Indicates a failure with the token `receiver`. Used in transfers.
    /// @param receiver Address to which tokens are being transferred.
    error ERC721InvalidReceiver(address receiver);

    /// @notice Indicates a failure with the token `sender`. Used in transfers.
    /// @param sender Address whose tokens are being transferred.
    error ERC721InvalidSender(address sender);

    /// @notice Indicates a `tokenId` whose `owner` is the zero address.
    /// @param tokenId Identifier number of a token.
    error ERC721NonexistentToken(uint256 tokenId);

    /// @notice A supplied deployment address, recipient or token is invalid.
    error InvalidAddress();

    /// @notice Range or calculated liquidity is outside the core's supported domain.
    error InvalidLiquidityAmounts();

    /// @notice Native value does not match the declared wrapped-native input.
    error InvalidNativeValue();

    /// @notice A recipient rejected a native-currency transfer.
    error NativeTransferFailed();

    /// @notice A requested input, output or liquidity limit was violated.
    error PeripherySlippage();

    /// @notice NFT cannot be destroyed while its core position has active liquidity.
    error PositionNotEmpty();

    /// @notice Unauthorized reentrant call.
    error ReentrancyGuardReentrantCall();

    /// @notice An operation with an ERC-20 token failed.
    error SafeERC20FailedOperation(address token);

    /// @notice The `value` string doesn't fit in the specified `length`.
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    /// @notice Caller is neither the NFT owner nor an approved operator.
    error UnauthorizedPosition();

    /// @notice Token transfer or wrapping does not deliver exactly the requested amount.
    error UnsupportedAsset();
}
