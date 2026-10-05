// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrenSwapper} from "../../src/frens/FrenSwapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

import {FrensRules} from "./FrensRules.sol";
/// @notice On a mainnet fork: the frens' floor buys IMD6900 through the live pools.
contract FrenSwapperForkTest is Test, FrensRules {
    using stdStorage for StdStorage;
    using PoolIdLibrary for *;
    using StateLibrary for IPoolManager;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant IMD6900 = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant X402_PROXY = 0x402085c248EeA27D92E8b30b2C58ed07f9E20001;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840; // IMD's ETH/IMD pool
    address constant PAIR_HOOK = 0x667f4621030aCfAfb1bD0B64d33610A8567f2A44;
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;

    IMD6900Frens frens;
    FrenSwapper swapper;
    address keeper = makeAddr("keeper");

    function setUp() public {
        // a mainnet fork: MAINNET_RPC_URL; without one (an offline machine) these tests skip
        string memory rpc_ = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        frens = new IMD6900Frens(address(this), IMD, IMD6900, IDENTITY, PERMIT2, X402_PROXY, makeAddr("payTo"), keeper, makeAddr("relayer"), _flatPrices());
        swapper = new FrenSwapper(POOL_MANAGER, IMD, IMD6900, address(frens), PAIR_HOOK, POOL4_HOOK);
        frens.setModules(address(swapper), address(0));
    }

    /// @notice Fee ETH buys the floor through $IMD: ETH -> $IMD on POOL4 -> IMD6900 on the pair pool. Both pools move.
    function test_FeeEthBuysTheFloorThroughImd() public {
        (uint160 pairBefore,,,) = IPoolManager(POOL_MANAGER).getSlot0(swapper.pairKey().toId());
        if (pairBefore == 0) vm.skip(true);
        (uint160 pool4Before,,,) = IPoolManager(POOL_MANAGER).getSlot0(swapper.imdKey().toId());
        assertGt(pool4Before, 0, "POOL4 is live");
        uint256 dust = address(swapper).balance; // a fork address can hold someone's dust already
        emit log_named_uint("swapper ETH before", dust);
        vm.deal(address(frens), 0.05 ether);
        vm.prank(keeper);
        frens.buyFloorWithEth(0.05 ether, 1);
        (uint160 pool4After,,,) = IPoolManager(POOL_MANAGER).getSlot0(swapper.imdKey().toId());
        (uint160 pairAfter,,,) = IPoolManager(POOL_MANAGER).getSlot0(swapper.pairKey().toId());
        assertLt(pool4After, pool4Before, "ETH bought $IMD on POOL4");
        assertTrue(pairAfter != pairBefore, "that $IMD bought IMD6900 on the pair pool");
        assertEq(IERC20(IMD).balanceOf(address(swapper)), 0, "no $IMD left in the swapper");
        uint256 got = frens.reserve();
        emit log_named_uint("IMD6900 for 0.05 ETH", got);
        assertGt(got, 0);
        emit log_named_uint("frens IMD6900", IERC20(IMD6900).balanceOf(address(frens)));
        emit log_named_uint("swapper IMD6900", IERC20(IMD6900).balanceOf(address(swapper)));
        emit log_named_uint("swapper ETH", address(swapper).balance);
        emit log_named_uint("frens ETH", address(frens).balance);
        assertEq(IERC20(IMD6900).balanceOf(address(frens)), got, "all of it in the reserve");
        assertEq(IERC20(IMD6900).balanceOf(address(swapper)), 0, "the swapper keeps nothing");
        assertEq(address(swapper).balance, dust, "the swapper keeps none of the ETH it was sent");
    }

    /// @notice The mint's 0.19 $IMD leg, bought into the floor through the live IMD6900/IMD pool (opened 2026-09-30).
    function test_ImdBuysTheFloorThroughThePairPool() public {
        (uint160 sqrtPrice,,,) = IPoolManager(POOL_MANAGER).getSlot0(swapper.pairKey().toId());
        if (sqrtPrice == 0) vm.skip(true); // before the pool is opened there is nothing to buy through
        emit log_named_uint("pair pool liquidity", IPoolManager(POOL_MANAGER).getLiquidity(swapper.pairKey().toId()));

        // one mint's worth of floor money, waiting to be bought (a real mint books it in floorImd)
        uint256 imdIn = 0.19e18;
        deal(IMD, address(frens), imdIn);
        stdstore.target(address(frens)).sig("floorImd()").checked_write(imdIn);
        assertEq(frens.floorImd(), imdIn);

        frens.buyFloor(1); // anyone

        uint256 got = frens.reserve();
        emit log_named_decimal_uint("IMD6900 bought with 0.19 $IMD", got, 18);
        assertGt(got, 0, "the floor grew");
        assertEq(IERC20(IMD6900).balanceOf(address(frens)), got, "all of it in the reserve");
        assertEq(IERC20(IMD6900).balanceOf(address(swapper)), 0, "the swapper keeps nothing");
        assertEq(IERC20(IMD).balanceOf(address(swapper)), 0, "and no $IMD either");
        assertEq(frens.floorImd(), 0, "the $IMD was spent");
    }

    /// @notice One block can't set what the mint counts IMD6900 at. Someone pushes the pair pool's price (IMD6900 dearer,
    ///         paying its fee) and a floor buy lands in that block: the average moves 1/64 of the way, not all of it.
    ///         Before, the first buy set it outright, and floorRate (the lower of it and the price now) would have kept
    ///         IMD6900 at the pushed price for every mint's quote long after the pool came back.
    function test_OneBlockCannotSetTheAverage() public {
        (uint160 p,,,) = IPoolManager(POOL_MANAGER).getSlot0(swapper.pairKey().toId());
        if (p == 0) vm.skip(true);
        uint256 spot0 = swapper.spotRate();
        assertApproxEqRel(swapper.rateAverage(), spot0, 1e12, "it starts at the pool's price");
        vm.roll(block.number + 1); // a block after the deploy's: this block's buy is sampled

        // anyone's buys, with the same price-limited route (a second swapper whose "frens" is this test): no fee waived
        FrenSwapper push = new FrenSwapper(POOL_MANAGER, IMD, IMD6900, address(this), PAIR_HOOK, POOL4_HOOK);
        deal(IMD, address(this), 1_000e18);
        IERC20(IMD).approve(address(push), type(uint256).max);
        uint256 spent = IERC20(IMD).balanceOf(address(this));
        for (uint256 i; i < 25; ++i) push.imdToImd6900(20e18, 0, address(this));
        spent -= IERC20(IMD).balanceOf(address(this));
        uint256 pushed = swapper.spotRate();
        emit log_named_decimal_uint("$IMD to push the price", spent, 18);
        emit log_named_uint("IMD6900 per $IMD before", spot0);
        emit log_named_uint("IMD6900 per $IMD pushed", pushed);
        assertLt(pushed, spot0 / 2, "IMD6900 at over twice its price");

        // a floor buy in that block
        deal(IMD, address(frens), 1e18);
        stdstore.target(address(frens)).sig("floorImd()").checked_write(uint256(1e18));
        frens.buyFloor(0);
        emit log_named_uint("average after", swapper.rateAverage());
        assertLt(swapper.rateAverage(), spot0, "the buy was sampled");
        assertGt(swapper.rateAverage(), spot0 * 63 / 64, "one sample moves it 1/64 of the way at most");
    }

    function test_OnlyFrensCanUseTheSwapper() public {
        vm.expectRevert(FrenSwapper.OnlyFrens.selector);
        swapper.ethToImd6900{value: 1}(0, address(this));
    }
}
