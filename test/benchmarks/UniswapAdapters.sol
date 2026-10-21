// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal ABI for the published v3 factory artifact.
interface IV3Factory {
    function createPool(address token0, address token1, uint24 fee) external returns (address);
}

/// @notice Minimal ABI for the published v3 pool artifact.
interface IV3Pool {
    function initialize(uint160 price) external;
    function setFeeProtocol(uint8 fee0, uint8 fee1) external;
    function mint(address owner, int24 lower, int24 upper, uint128 liquidity, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    function burn(int24 lower, int24 upper, uint128 liquidity) external returns (uint256 amount0, uint256 amount1);
    function collect(address recipient, int24 lower, int24 upper, uint128 amount0, uint128 amount1)
        external
        returns (uint128 collected0, uint128 collected1);
    function swap(address recipient, bool down, int256 amount, uint160 limit, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @notice ABI-compatible types for the unmodified, separately compiled v4 manager artifact.
interface IV4Manager {
    struct Key {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct Modify {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    struct Swap {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }
    function initialize(Key calldata key, uint160 price) external returns (int24);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(Key calldata key, Modify calldata params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function swap(Key calldata key, Swap calldata params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address recipient, uint256 amount) external;
    function mint(address recipient, uint256 id, uint256 amount) external;
    function burn(address owner, uint256 id, uint256 amount) external;
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function setOperator(address operator, bool approved) external returns (bool);
    function setProtocolFeeController(address controller) external;
    function setProtocolFee(Key calldata key, uint24 fee) external;
}

/// @notice Test-only minimal v3 callback adapter; excludes NFT and production router bookkeeping.
/// @dev One fixture owner controls its positions. Tokens move directly between owner and pool.
contract V3BenchmarkAdapter {
    IV3Pool public immutable pool;
    address public immutable owner;
    IERC20 private immutable token0;
    IERC20 private immutable token1;

    constructor(IV3Pool pool_, address token0_, address token1_, address owner_) {
        pool = pool_;
        token0 = IERC20(token0_);
        token1 = IERC20(token1_);
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    function mint(int24 lower, int24 upper, uint128 liquidity)
        external
        onlyOwner
        returns (uint256 amount0, uint256 amount1)
    {
        return pool.mint(address(this), lower, upper, liquidity, "");
    }

    /// @notice Burn (or poke when zero), then transfer all principal and earned fees to the owner.
    function exit(int24 lower, int24 upper, uint128 liquidity)
        external
        onlyOwner
        returns (uint128 amount0, uint128 amount1)
    {
        pool.burn(lower, upper, liquidity);
        return pool.collect(owner, lower, upper, type(uint128).max, type(uint128).max);
    }

    function swap(bool down, uint128 input, uint160 limit) external onlyOwner returns (uint256 spent, uint256 output) {
        (int256 d0, int256 d1) = pool.swap(owner, down, int256(uint256(input)), limit, "");
        return down ? (uint256(d0), uint256(-d1)) : (uint256(d1), uint256(-d0));
    }

    /// @notice Close one range, collect its assets, then open a narrower range for the same owner.
    function rebalance(int24 lower, int24 upper, int24 nextLower, int24 nextUpper, uint128 liquidity)
        external
        onlyOwner
        returns (uint256 net0, uint256 net1)
    {
        pool.burn(lower, upper, liquidity);
        (uint128 received0, uint128 received1) = pool.collect(owner, lower, upper, type(uint128).max, type(uint128).max);
        (uint256 spent0, uint256 spent1) = pool.mint(address(this), nextLower, nextUpper, liquidity, "");
        return (received0 - spent0, received1 - spent1);
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(pool));
        if (amount0 != 0) require(token0.transferFrom(owner, msg.sender, amount0));
        if (amount1 != 0) require(token1.transferFrom(owner, msg.sender, amount1));
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        require(msg.sender == address(pool));
        if (amount0 > 0) require(token0.transferFrom(owner, msg.sender, uint256(amount0)));
        if (amount1 > 0) require(token1.transferFrom(owner, msg.sender, uint256(amount1)));
    }
}

/// @notice Test-only v4 adapter with either ERC-20 wallet settlement or existing ERC-6909 claims.
/// @dev Uses real unlock, transient deltas, settlement and claim accounting. No storage is mocked.
contract V4BenchmarkAdapter {
    IV4Manager public immutable manager;
    address public immutable owner;
    address private immutable token0;
    address private immutable token1;
    bool public immutable claims;

    constructor(IV4Manager manager_, address token0_, address token1_, address owner_, bool claims_) {
        manager = manager_;
        token0 = token0_;
        token1 = token1_;
        owner = owner_;
        claims = claims_;
    }

    function key() public view returns (IV4Manager.Key memory) {
        // 125 ppm protocol + 375 ppm LP = 500 ppm effective swap fee after integer composition.
        return IV4Manager.Key(token0, token1, 375, 10, address(0));
    }

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    function modify(int24 lower, int24 upper, int128 liquidity)
        external
        onlyOwner
        returns (int128 amount0, int128 amount1)
    {
        bytes memory result = manager.unlock(abi.encode(uint8(0), lower, upper, liquidity));
        return abi.decode(result, (int128, int128));
    }

    function swap(bool down, uint128 input, uint160 limit) external onlyOwner returns (uint256 spent, uint256 output) {
        (int128 d0, int128 d1) = abi.decode(manager.unlock(abi.encode(uint8(1), down, input, limit)), (int128, int128));
        return down ? (uint128(-d0), uint128(d1)) : (uint128(-d1), uint128(d0));
    }

    function fundClaims(uint256 amount) external onlyOwner {
        require(claims);
        manager.unlock(abi.encode(uint8(2), amount));
    }

    /// @notice Change ranges inside one unlock and settle only the net asset changes.
    function rebalance(int24 lower, int24 upper, int24 nextLower, int24 nextUpper, uint128 liquidity)
        external
        onlyOwner
        returns (int128 amount0, int128 amount1)
    {
        bytes memory result = manager.unlock(abi.encode(uint8(3), lower, upper, nextLower, nextUpper, liquidity));
        return abi.decode(result, (int128, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint8 action = abi.decode(data, (uint8));
        if (action == 2) {
            (, uint256 amount) = abi.decode(data, (uint8, uint256));
            _fund(token0, amount);
            _fund(token1, amount);
            return "";
        }
        if (action == 3) {
            (, int24 lower, int24 upper, int24 nextLower, int24 nextUpper, uint128 liquidity) =
                abi.decode(data, (uint8, int24, int24, int24, int24, uint128));
            (int256 oldDelta,) =
                manager.modifyLiquidity(key(), IV4Manager.Modify(lower, upper, -int256(uint256(liquidity)), 0), "");
            (int256 newDelta,) = manager.modifyLiquidity(
                key(), IV4Manager.Modify(nextLower, nextUpper, int256(uint256(liquidity)), 0), ""
            );
            int128 amount0 = int128(oldDelta >> 128) + int128(newDelta >> 128);
            int128 amount1 = int128(oldDelta) + int128(newDelta);
            _settle(token0, amount0);
            _settle(token1, amount1);
            return abi.encode(amount0, amount1);
        }
        int256 delta;
        if (action == 0) {
            (, int24 lower, int24 upper, int128 liquidity) = abi.decode(data, (uint8, int24, int24, int128));
            (delta,) = manager.modifyLiquidity(key(), IV4Manager.Modify(lower, upper, liquidity, 0), "");
        } else {
            (, bool down, uint128 input, uint160 limit) = abi.decode(data, (uint8, bool, uint128, uint160));
            delta = manager.swap(key(), IV4Manager.Swap(down, -int256(uint256(input)), limit), "");
        }
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        _settle(token0, d0);
        _settle(token1, d1);
        return abi.encode(d0, d1);
    }

    function _fund(address token, uint256 amount) private {
        manager.sync(token);
        require(IERC20(token).transferFrom(owner, address(manager), amount));
        require(manager.settle() == amount);
        manager.mint(owner, uint160(token), amount);
    }

    function _settle(address token, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint128(-delta);
            if (claims) {
                manager.burn(owner, uint160(token), amount);
            } else {
                manager.sync(token);
                require(IERC20(token).transferFrom(owner, address(manager), amount));
                require(manager.settle() == amount);
            }
        } else if (delta > 0) {
            if (claims) manager.mint(owner, uint160(token), uint128(delta));
            else manager.take(token, owner, uint128(delta));
        }
    }
}
