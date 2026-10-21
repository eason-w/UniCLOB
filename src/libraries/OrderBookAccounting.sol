// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import { ConcentratedRangeBook as Book } from "../ConcentratedRangeBook.sol";
import { TickMath } from "../vendor/uniswap/TickMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickTree } from "./TickTree.sol";
import { AdaptiveFifoQueue as FifoQueue } from "./AdaptiveFifoQueue.sol";
import { ConcentratedLiquidity as CL } from "./ConcentratedLiquidity.sol";

/// @title OrderBookAccounting
/// @notice Linked FIFO order accounting; custody and owner authorization remain in the exchange.
/// @dev All methods run by delegatecall under the exchange reentrancy lock.
library OrderBookAccounting {
    using TickTree for TickTree.Map;
    using FifoQueue for FifoQueue.Queue;

    /// @notice Validates and initializes an immutable market without administrative privileges.
    /// @param markets Exchange market storage.
    /// @param c Immutable token, grid, fee, lot and initial-price parameters.
    /// @return id Market identifier: keccak256(abi.encode(c)).
    function create(mapping(bytes32 => Book.Market) storage markets, Book.Config calldata c)
        public
        returns (bytes32 id)
    {
        if (
            c.token0 == c.token1 || c.token0.code.length == 0 || c.token1.code.length == 0 || c.orderLot == 0
                || c.tickSpacing <= 0 || c.tickSpacing > 32_767 || c.feePpm == 0 || c.feePpm > 100_000
                || c.protocolDivisor < 2 || c.protocolDivisor > 10
                || ((c.feePpm == 100 || c.feePpm == 500) && c.protocolDivisor != 4)
                || ((c.feePpm == 3000 || c.feePpm == 10_000) && c.protocolDivisor != 6)
        ) revert Book.InvalidConfiguration();
        id = keccak256(abi.encode(c));
        Book.Market storage m = markets[id];
        if (m.config.token0 != address(0)) revert Book.MarketExists();
        m.config = c;
        CL.initialize(m.curve, c.initialSqrtPriceX96);
        emit Book.MarketCreated(id, c);
    }

    /// @notice Appends a funded quote and records its collateral obligation.
    /// @param m Market state.
    /// @param o New or fully settled order record.
    /// @param id Market identifier.
    /// @param ask True sells base lots.
    /// @param tick Aligned limit price.
    /// @param lots Positive base-lot quantity.
    /// @return collateral Token atoms that the exchange must debit from the owner.
    function place(Book.Market storage m, Book.StoredOrder storage o, bytes32 id, bool ask, int24 tick, uint128 lots)
        public
        returns (uint256 collateral)
    {
        if (tick <= TickMath.MIN_TICK || tick >= TickMath.MAX_TICK || tick % m.config.tickSpacing != 0) {
            revert Book.InvalidPrice();
        }
        if (lots == 0) revert Book.InvalidAmount();
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        if (ask ? price < m.curve.sqrtPriceX96 : price > m.curve.sqrtPriceX96) revert Book.MarketableOrder();
        (bool found, int24 other) =
            ask ? m.bids.best(false, m.config.tickSpacing) : m.asks.best(true, m.config.tickSpacing);
        if (found && (ask ? tick <= other : tick >= other)) revert Book.MarketableOrder();
        uint256 base = uint256(lots) * m.config.orderLot;
        uint256 quote = _quote(price, base, true);
        if (base > type(uint128).max || quote > type(uint128).max || _quote(price, m.config.orderLot, false) == 0) {
            revert Book.InvalidAmount();
        }
        FifoQueue.Queue storage q = ask ? m.askQueues[tick] : m.bidQueues[tick];
        // Only replacement reuses an owned record; ordinary placement preserves its existing queue semantics.
        if (o.owner != address(0)) q.restartIfEmpty();
        (uint64 generation, uint32 sequence) = q.append(lots);
        o.marketId = id;
        o.owner = msg.sender;
        o.tick = tick;
        o.ask = ask;
        o.generation = generation;
        o.sequence = sequence;
        o.posted = uint64(lots);
        o.cancelled = 0;
        o.claimed = 0;
        collateral = ask ? base : quote;
        if (ask) {
            m.orderReserve0 += base;
            m.asks.set(tick, true, m.config.tickSpacing);
        } else {
            m.orderReserve1 += quote;
            m.bids.set(tick, true, m.config.tickSpacing);
        }
    }

    /// @notice Reads an order's metadata, remaining lots and unclaimed executed lots.
    /// @param stored Stored order record; a missing record returns all zeros.
    /// @param markets Exchange market storage.
    /// @return o Order metadata.
    /// @return remaining Unfilled and uncancelled lots.
    /// @return claimable Filled lots whose proceeds have not been claimed.
    function get(Book.StoredOrder storage stored, mapping(bytes32 => Book.Market) storage markets)
        public
        view
        returns (Book.Order memory o, uint128 remaining, uint128 claimable)
    {
        o = Book.Order(
            stored.marketId,
            stored.owner,
            stored.tick,
            stored.ask,
            stored.generation,
            stored.sequence,
            stored.posted,
            stored.cancelled,
            stored.claimed
        );
        if (o.owner == address(0)) return (o, 0, 0);
        Book.Market storage m = markets[o.marketId];
        FifoQueue.Queue storage q = o.ask ? m.askQueues[o.tick] : m.bidQueues[o.tick];
        remaining = q.remaining(o.generation, o.sequence);
        claimable = o.posted - o.cancelled - remaining - o.claimed;
    }

    /// @notice Reads the next live ordinary level, inclusive of the requested tick.
    /// @param m Existing market state.
    /// @param ask True walks asks upward; false walks bids downward.
    /// @param from Inclusive starting tick; need not be aligned.
    /// @return found Whether a live level exists.
    /// @return tick Located price tick, or zero when absent.
    /// @return lots Total remaining base lots at that level, or zero when absent.
    function nextLevel(Book.Market storage m, bool ask, int24 from)
        public
        view
        returns (bool found, int24 tick, uint128 lots)
    {
        (found, tick) =
            ask ? m.asks.next(from, true, m.config.tickSpacing) : m.bids.next(from, false, m.config.tickSpacing);
        if (!found) return (false, 0, 0);
        lots = ask ? m.askQueues[tick].total() : m.bidQueues[tick].total();
    }

    function _quote(uint160 price, uint256 base, bool up) private pure returns (uint256) {
        uint256 n;
        uint256 d;
        if (price <= type(uint128).max) {
            n = uint256(price) * price;
            d = 1 << 192;
        } else {
            n = Math.mulDiv(price, price, 1 << 64);
            d = 1 << 128;
        }
        return Math.mulDiv(base, n, d, up ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }
}
