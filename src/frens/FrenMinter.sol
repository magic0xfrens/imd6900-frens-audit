// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IFrensMint {
    function imd() external view returns (address);
    function imd6900() external view returns (address);
    function identity() external view returns (address);
    function quote(uint256 count) external view returns (uint256);
    function floorImd() external view returns (uint256);
    function requestMintFor(address minter, uint8 count, uint256 maxPay) external returns (uint256);
    function maxMint(uint256 tier) external view returns (uint8);
    function imdTier(uint256 i) external view returns (uint256);
    function imd6900Tier(uint256 i) external view returns (uint256);
    function identityTier(uint256 i) external view returns (uint256);
}

interface IBalance {
    function balanceOf(address) external view returns (uint256);
}

/// @title FrenMinter - mint IMD6900 frens with ETH, and the quotes the site and the keeper need
/// @notice Buys exactly the $IMD the frens cost on IMD's own ETH/$IMD pool (POOL4, through its hook: its fee and burn
///         apply), pays the frens contract with it for the caller, and sends back the ETH it didn't spend. The frens,
///         the request and the tier are the caller's; paying in ETH leaves their $IMD, and so their tier, as it is.
///         The frens contract's keeper then buys that $IMD into IMD6900 for the floor: ETH -> $IMD -> IMD6900.
///         It holds nothing between calls.
contract FrenMinter is ReentrancyGuard {
    IPoolManager public immutable poolManager;
    IFrensMint public immutable frens;
    address public immutable imd;
    address public immutable imdPoolHook; // POOL4's hook (fee 1%, tick spacing 60)
    address public immutable imd6900;
    address public immutable pairHook; // the IMD6900/$IMD pool's hook

    error OnlyPoolManager();
    error Short();
    error TooPricey(uint256 cost);
    error NotEnoughEth(uint256 needed);
    error Quoted(uint256 ethIn, uint256 imdOut);

    constructor(address poolManager_, address frens_, address imdPoolHook_, address pairHook_) {
        poolManager = IPoolManager(poolManager_);
        frens = IFrensMint(frens_);
        imd = IFrensMint(frens_).imd();
        imd6900 = IFrensMint(frens_).imd6900();
        imdPoolHook = imdPoolHook_;
        pairHook = pairHook_;
    }

    /// @notice The IMD6900/$IMD pool, where the floor buys its IMD6900
    function pairKey() public view returns (PoolKey memory) {
        (address a, address b) = imd6900 < imd ? (imd6900, imd) : (imd, imd6900);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 0, 60, IHooks(pairHook));
    }

    /// @notice POOL4: ETH/$IMD
    function imdKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(imd), 10_000, 60, IHooks(imdPoolHook));
    }

    /// @notice Mints `count` frens for the caller with the ETH sent: buys their price in $IMD (at most `maxPay` $IMD:
    ///         the curve moves as others mint), requests them, and refunds the ETH left. Send a little more ETH than
    ///         quoteEth says: the pool moves too.
    function mintWithEth(uint8 count, uint256 maxPay) external payable nonReentrant returns (uint256 requestId, uint256 ethSpent) {
        uint256 cost = frens.quote(count);
        if (cost > maxPay) revert TooPricey(cost);
        ethSpent = abi.decode(poolManager.unlock(abi.encode(MINT, cost, msg.value)), (uint256));
        SafeTransferLib.safeApprove(imd, address(frens), cost);
        requestId = frens.requestMintFor(msg.sender, count, cost);
        uint256 extra = IBalance(imd).balanceOf(address(this)); // a hook that gives a little more than asked
        if (extra != 0) SafeTransferLib.safeTransfer(imd, msg.sender, extra);
        if (msg.value > ethSpent) SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethSpent);
    }

    /// @notice Buys exactly `imdOut` $IMD with the ETH sent, on POOL4, for the caller, and refunds the ETH left: how the
    ///         owner pays the frens it mints before the opening (requestMintFor while the mint is closed)
    function buyImd(uint256 imdOut) external payable nonReentrant returns (uint256 ethSpent) {
        ethSpent = abi.decode(poolManager.unlock(abi.encode(MINT, imdOut, msg.value)), (uint256));
        SafeTransferLib.safeTransfer(imd, msg.sender, IBalance(imd).balanceOf(address(this)));
        if (msg.value > ethSpent) SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethSpent);
    }

    /// @notice The ETH `count` frens cost right now, through the pool (fee and hook included). Not a view: call it
    ///         with eth_call. It runs the swap and reverts inside, so nothing happens.
    function quoteEth(uint8 count) external returns (uint256 ethIn, uint256 imdOut) {
        return _quote(QUOTE_MINT, frens.quote(count));
    }

    /// @notice The IMD6900 `imdIn` $IMD buys on the IMD6900/$IMD pool now (what buyFloor would get). eth_call it.
    function quoteFloor(uint256 imdIn) external returns (uint256 imdIn_, uint256 imd6900Out) {
        return _quote(QUOTE_FLOOR, imdIn);
    }

    /// @notice The IMD6900 `ethIn` ETH buys through $IMD now (what buyFloorWithEth would get). eth_call it.
    function quoteFloorEth(uint256 ethIn) external returns (uint256 ethIn_, uint256 imd6900Out) {
        return _quote(QUOTE_FLOOR_ETH, ethIn);
    }

    uint8 internal constant MINT = 0;
    uint8 internal constant QUOTE_MINT = 1;
    uint8 internal constant QUOTE_FLOOR = 2;
    uint8 internal constant QUOTE_FLOOR_ETH = 3;

    /// @dev Runs a swap inside the PoolManager's lock and reverts with what went in and came out: nothing happens
    function _quote(uint8 mode, uint256 amount) internal returns (uint256 inAmount, uint256 outAmount) {
        try poolManager.unlock(abi.encode(mode, amount, 0)) {}
        catch (bytes memory r) {
            if (r.length == 68 && bytes4(r) == Quoted.selector) {
                assembly {
                    inAmount := mload(add(r, 36))
                    outAmount := mload(add(r, 68))
                }
                return (inAmount, outAmount);
            }
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint8 mode, uint256 amount, uint256 ethMax) = abi.decode(raw, (uint8, uint256, uint256));
        if (mode >= QUOTE_FLOOR) {
            uint256 imdIn = amount;
            if (mode == QUOTE_FLOOR_ETH) {
                BalanceDelta e = poolManager.swap(
                    imdKey(), SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ""
                );
                imdIn = uint256(uint128(e.amount1()));
            }
            PoolKey memory pair = pairKey();
            bool imdIs0 = Currency.unwrap(pair.currency0) == imd;
            BalanceDelta p = poolManager.swap(
                pair,
                SwapParams({
                    zeroForOne: imdIs0,
                    amountSpecified: -int256(imdIn),
                    sqrtPriceLimitX96: imdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            revert Quoted(amount, uint256(uint128(imdIs0 ? p.amount1() : p.amount0())));
        }
        // exact output: ETH in, exactly `amount` $IMD out
        uint256 imdOut = amount;
        BalanceDelta d = poolManager.swap(
            imdKey(), SwapParams({zeroForOne: true, amountSpecified: int256(imdOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ""
        );
        uint256 ethIn = uint256(uint128(-d.amount0()));
        uint256 got = uint256(uint128(d.amount1()));
        if (mode == QUOTE_MINT) revert Quoted(ethIn, got);
        if (got < imdOut) revert Short();
        if (ethIn > ethMax) revert NotEnoughEth(ethIn);
        poolManager.settle{value: ethIn}();
        poolManager.take(Currency.wrap(imd), address(this), got);
        return abi.encode(ethIn);
    }

    /// @notice The most frens `account` can ask for in one request now. Paying in $IMD takes the price out of the bag
    ///         before the tier is read (and needs the $IMD); paying in ETH leaves the bag as it is.
    function maxRequest(address account, bool withEth) external view returns (uint256 n) {
        uint256 a = IBalance(imd).balanceOf(account);
        uint256 b = IBalance(frens.imd6900()).balanceOf(account);
        uint256 c = IBalance(frens.identity()).balanceOf(account);
        for (n = 69; n > 0; --n) {
            uint256 cost;
            try frens.quote(n) returns (uint256 q) {
                cost = q;
            } catch {
                continue; // fewer than n frens left
            }
            if (!withEth && cost > a) continue;
            if (n <= frens.maxMint(_tier(withEth ? a : a - cost, b, c))) return n;
        }
    }

    function _tier(uint256 a, uint256 b, uint256 c) internal view returns (uint256) {
        for (uint256 t = 3; t > 0; --t) {
            if (a >= frens.imdTier(t - 1) || b >= frens.imd6900Tier(t - 1) || c >= frens.identityTier(t - 1)) return t;
        }
        return 0;
    }
}
