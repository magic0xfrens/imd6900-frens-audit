// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IFrenSwapper} from "./IMD6900Frens.sol";

interface IPairFee {
    function fee() external view returns (uint256); // the launch pool's fee, in bips, that every trade here pays
}

/// @title FrenSwapper - buys the frens' floor: $IMD through the IMD6900/IMD pool, and fee ETH through $IMD first
/// @notice Only the frens contract calls it. It holds nothing between calls: what comes in is swapped, and all the
///         IMD6900 out goes straight to `to`. The minimum out is checked here and again by the frens contract.
///         ETH (royalties, the launch hook's fee slice) goes ETH -> $IMD on IMD's own pool (POOL4) -> IMD6900 on the
///         IMD6900/IMD pool: every fee is buy pressure on both tokens, and POOL4's hook burns its share of $IMD.
///
///         No buy can be worth sandwiching: each swap stops once it has moved its pool's price by half that pool's fee
///         (the IMD6900/$IMD pool charges the launch pool's fee on every trade's output; POOL4 is held to 0.5%). A
///         sandwich pays the fee twice, on the way in and out, so it can't earn back more than the buy moves the
///         price. What a swap leaves at its limit goes back to the frens contract, for the next buy.
///
///         It also prices IMD6900 for the frens' mint, which must never cost less than the floor it joins:
///         floorRate() is the lower of two readings of IMD6900 per $IMD, so IMD6900 counts at its dearest: the pool's
///         price now, and a slow average of what the floor's own buys paid (fee and impact included). One trade can
///         move the first; the second moves 1/64 of the way a block, and only when the floor buys, so pushing both
///         means holding the pool off its price for many blocks, against arbitrage, while the floor buys cheap.
/// @dev Exact-input swaps inside one PoolManager unlock, as ArbVaultV2 does: pay the input in, take IMD6900 out, so
///      the IMD6900 hook's allowance is spent by the transfer it was granted for. On the ETH route the $IMD never
///      leaves the PoolManager: the second swap spends the first one's credit (flash accounting).
contract FrenSwapper is IFrenSwapper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BIPS = 10_000;
    uint256 public constant POOL4_MOVE_BIPS = 50; // POOL4's price moves at most 0.5% a buy

    /// @notice A slow average of the IMD6900 the floor's buys got per $IMD (1e18), and the block it last moved
    uint256 public rateAverage;
    uint256 public averagedAt;
    IPoolManager public immutable poolManager;
    address public immutable imd;
    address public immutable imd6900;
    address public immutable frens;
    address public immutable pairHook; // the IMD6900/IMD pool's hook
    address public immutable imdPoolHook; // POOL4's hook: IMD's ETH/IMD pool (fee 1%, tick spacing 60)

    error OnlyFrens();
    error OnlyPoolManager();
    error Short();

    constructor(address poolManager_, address imd_, address imd6900_, address frens_, address pairHook_, address imdPoolHook_) {
        poolManager = IPoolManager(poolManager_);
        imd = imd_;
        imd6900 = imd6900_;
        frens = frens_;
        pairHook = pairHook_;
        imdPoolHook = imdPoolHook_;
        // the average starts at the pool's price now, so no one block's buy can set it: each moves it 1/64 of the way
        PoolKey memory key = _pairKey(imd_, imd6900_, pairHook_);
        (uint160 p,,,) = IPoolManager(poolManager_).getSlot0(key.toId());
        if (p != 0) (rateAverage, averagedAt) = (_rate(p, Currency.unwrap(key.currency0) == imd_), block.number);
    }

    function pairKey() public view returns (PoolKey memory) {
        return _pairKey(imd, imd6900, pairHook);
    }

    function _pairKey(address imd_, address imd6900_, address hook) internal pure returns (PoolKey memory) {
        (address a, address b) = imd6900_ < imd_ ? (imd6900_, imd_) : (imd_, imd6900_);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 0, 60, IHooks(hook));
    }

    /// @notice POOL4: ETH/IMD, where the launcher buys its $IMD too
    function imdKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(imd), 10_000, 60, IHooks(imdPoolHook));
    }

    /// @notice IMD6900 per $IMD at the IMD6900/$IMD pool's price now (1e18)
    function spotRate() public view returns (uint256) {
        PoolKey memory key = pairKey();
        (uint160 p,,,) = poolManager.getSlot0(key.toId());
        return _rate(p, Currency.unwrap(key.currency0) == imd);
    }

    /// @dev IMD6900 per $IMD (1e18) at sqrt price `p`: the pool's price is currency1 per currency0, (p / 2^96)^2
    function _rate(uint160 p, bool imdIs0) internal pure returns (uint256) {
        return imdIs0
            ? FullMath.mulDiv(FullMath.mulDiv(p, p, 1 << 96), 1e18, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(1 << 96, 1 << 96, p), 1e18, p);
    }

    /// @notice IMD6900 per $IMD at its dearest of the pool's price now and the floor buys' average (1e18): what the
    ///         frens contract values its IMD6900 at when it prices a mint
    function floorRate() external view returns (uint256 rate) {
        rate = spotRate();
        if (rateAverage != 0 && rateAverage < rate) rate = rateAverage;
    }

    /// @dev Moves the average 1/64 of the way to a buy's rate, once a block at most (it starts at the pool's price when
    ///      this is deployed; only if the pool wasn't open then does the first buy set it)
    function _average(uint256 imdIn, uint256 out) internal {
        if (imdIn == 0 || out == 0 || averagedAt == block.number) return;
        uint256 r = out * 1e18 / imdIn;
        rateAverage = rateAverage == 0 ? r : rateAverage - rateAverage / 64 + r / 64;
        averagedAt = block.number;
    }

    /// @notice The most a buy may move the IMD6900/$IMD pool's price, in bips: half the fee every trade there pays
    function pairMoveBips() public view returns (uint256) {
        return IPairFee(pairHook).fee() / 2;
    }

    /// @dev The price limit `moveBips` away from the pool's price now, in the swap's direction
    function _limit(PoolKey memory key, bool zeroForOne, uint256 moveBips) internal view returns (uint160) {
        (uint160 p,,,) = poolManager.getSlot0(key.toId());
        uint256 f = Math.sqrt((BIPS + moveBips) * 1e36 / BIPS); // sqrt(1 + move), 1e18: the price is sqrtP squared
        return uint160(zeroForOne ? uint256(p) * 1e18 / f : uint256(p) * f / 1e18);
    }

    /// @notice Pulls `imdIn` $IMD from the frens contract and swaps it into IMD6900 for `to`, until the price limit;
    ///         what's left goes back.
    function imdToImd6900(uint256 imdIn, uint256 minOut, address to) external returns (uint256 out) {
        if (msg.sender != frens) revert OnlyFrens();
        SafeTransferLib.safeTransferFrom(imd, frens, address(this), imdIn);
        PoolKey memory key = pairKey();
        out = abi.decode(poolManager.unlock(abi.encode(false, abi.encode(key, Currency.unwrap(key.currency0) == imd, imdIn, to))), (uint256));
        if (out < minOut) revert Short();
    }

    /// @notice Swaps the ETH sent with the call into IMD6900 for `to`, through $IMD: ETH -> $IMD on POOL4, then all of
    ///         that $IMD -> IMD6900 on the IMD6900/IMD pool.
    function ethToImd6900(uint256 minOut, address to) external payable returns (uint256 out) {
        if (msg.sender != frens) revert OnlyFrens();
        out = abi.decode(poolManager.unlock(abi.encode(true, abi.encode(msg.value, to))), (uint256));
        if (out < minOut) revert Short();
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (bool viaImd, bytes memory data) = abi.decode(raw, (bool, bytes));
        if (viaImd) return _ethViaImd(data);
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address to) = abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: _limit(key, zeroForOne, pairMoveBips())}),
            ""
        );
        (int128 paid, int128 got) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        Currency tokenIn = zeroForOne ? key.currency0 : key.currency1;
        Currency tokenOut = zeroForOne ? key.currency1 : key.currency0;
        uint256 pay = uint256(uint128(-paid));
        if (tokenIn.isAddressZero()) {
            poolManager.settle{value: pay}();
        } else {
            poolManager.sync(tokenIn);
            SafeTransferLib.safeTransfer(Currency.unwrap(tokenIn), address(poolManager), pay);
            poolManager.settle();
        }
        uint256 out = uint256(uint128(got));
        poolManager.take(tokenOut, to, out);
        _average(pay, out);
        // an exact-input swap can leave input unspent at the price limit: send it back to the frens contract
        if (pay < amountIn) {
            if (tokenIn.isAddressZero()) SafeTransferLib.safeTransferETH(frens, amountIn - pay);
            else SafeTransferLib.safeTransfer(Currency.unwrap(tokenIn), frens, amountIn - pay);
        }
        return abi.encode(out);
    }

    /// @dev ETH -> $IMD (POOL4) -> IMD6900 (IMD6900/IMD), one unlock: the second swap spends the $IMD the first one is
    ///      owed, so only the ETH is settled and only the IMD6900 is taken. Input left at a price limit goes back to
    ///      the frens contract (ETH, or $IMD it books for the next floor buy).
    function _ethViaImd(bytes memory data) internal returns (bytes memory) {
        (uint256 ethIn, address to) = abi.decode(data, (uint256, address));
        PoolKey memory pool4 = imdKey();
        BalanceDelta d1 = poolManager.swap(
            pool4, SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: _limit(pool4, true, POOL4_MOVE_BIPS)}), ""
        );
        uint256 ethPaid = uint256(uint128(-d1.amount0()));
        uint256 imdGot = uint256(uint128(d1.amount1()));
        PoolKey memory pair = pairKey();
        bool imdIs0 = Currency.unwrap(pair.currency0) == imd;
        BalanceDelta d2 = poolManager.swap(
            pair,
            SwapParams({zeroForOne: imdIs0, amountSpecified: -int256(imdGot), sqrtPriceLimitX96: _limit(pair, imdIs0, pairMoveBips())}),
            ""
        );
        (int128 paid, int128 got) = imdIs0 ? (d2.amount0(), d2.amount1()) : (d2.amount1(), d2.amount0());
        uint256 imdPaid = uint256(uint128(-paid));
        uint256 out = uint256(uint128(got));
        _average(imdPaid, out);
        poolManager.settle{value: ethPaid}();
        poolManager.take(Currency.wrap(imd6900), to, out);
        if (imdGot > imdPaid) poolManager.take(Currency.wrap(imd), frens, imdGot - imdPaid);
        if (ethIn > ethPaid) SafeTransferLib.safeTransferETH(frens, ethIn - ethPaid);
        return abi.encode(out);
    }
}
