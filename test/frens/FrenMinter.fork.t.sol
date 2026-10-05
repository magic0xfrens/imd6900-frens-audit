// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployFrens} from "../../script/frens/DeployFrens.s.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrenMinter} from "../../src/frens/FrenMinter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice On a mainnet fork: minting with ETH buys exactly the frens' price in $IMD on IMD's live ETH/$IMD pool (POOL4,
///         through its hook), requests the frens for the caller, and refunds the ETH it didn't spend.
contract FrenMinterForkTest is Test {
    using stdStorage for StdStorage;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    DeployFrens s;
    DeployFrens.Deployed d;
    address minter = address(uint160(uint256(keccak256("eth minter"))));
    address keeper = address(uint160(uint256(keccak256("keeper"))));

    function setUp() public {
        // a mainnet fork: MAINNET_RPC_URL; without one (an offline machine) these tests skip
        string memory rpc_ = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        s = new DeployFrens();
        d = s.deploy(address(s), address(uint160(uint256(keccak256("keeper")))), address(uint160(uint256(keccak256("relayer")))));
        vm.startPrank(address(s));
        d.frens.setMintOpen(true);
        d.gate.openPublic(); // the public mint (the workers' window: DeployFrens.fork)
        vm.stopPrank();
        vm.deal(minter, 10 ether);
    }

    function test_QuoteEth() public {
        (uint256 ethIn, uint256 imdOut) = d.minter.quoteEth(1);
        assertEq(imdOut, 0.69e18, "exactly the price");
        assertGt(ethIn, 0);
        (uint256 eth10,) = d.minter.quoteEth(10);
        assertGt(eth10, ethIn * 9);
        emit log_named_decimal_uint("ETH for 1 fren", ethIn, 18);
        emit log_named_decimal_uint("ETH for 10 frens", eth10, 18);
    }

    function test_MintWithEth() public {
        deal(s.IMD(), minter, 70e18); // tier 2: up to 22 a request; paying in ETH doesn't touch it
        uint256 cost = d.frens.quote(10);
        (uint256 ethIn,) = d.minter.quoteEth(10);
        uint256 send = ethIn * 102 / 100;
        uint256 before = minter.balance;
        vm.prank(minter);
        (uint256 id, uint256 spent) = d.minter.mintWithEth{value: send}(10, cost);
        assertEq(spent, ethIn, "what the quote said");
        assertEq(before - minter.balance, spent, "the rest came back");
        (address who, uint8 tier,,, uint8 count,,,,,) = d.frens.requests(id);
        assertEq(who, minter);
        assertEq(tier, 2);
        assertEq(count, 10);
        assertEq(IERC20(s.IMD()).balanceOf(minter), 70e18, "the minter's $IMD untouched");
        assertEq(IERC20(s.IMD()).balanceOf(address(d.frens)), d.frens.jobBudget() + d.frens.floorImd(), "the job's part and what waits");
        assertEq(d.frens.jobBudget(), 0.5e18);
        assertGt(d.frens.reserve(), 0, "the rest already bought IMD6900");
        assertLt(d.frens.floorImd(), cost - 0.5e18);
        assertEq(address(d.minter).balance, 0, "holds nothing");
        assertEq(IERC20(s.IMD()).balanceOf(address(d.minter)), 0);
    }

    function test_MintWithEthNeedsEnoughEth() public {
        (uint256 ethIn,) = d.minter.quoteEth(1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(FrenMinter.NotEnoughEth.selector, ethIn));
        d.minter.mintWithEth{value: ethIn - 1}(1, type(uint256).max);
    }

    function test_MintWithEthMaxPay() public {
        uint256 cost = d.frens.quote(1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(FrenMinter.TooPricey.selector, cost));
        d.minter.mintWithEth{value: 1 ether}(1, cost - 1);
    }

    /// @dev Paying in ETH leaves the minter's tier as their bag has it; the tier limit is theirs
    function test_TierLimitIsTheMinters() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IMD6900Frens.OverTierLimit.selector, uint8(1)));
        d.minter.mintWithEth{value: 1 ether}(2, type(uint256).max);
        assertEq(d.minter.maxRequest(minter, true), 1);
    }

    function _pairPrice() internal view returns (uint256) {
        (uint160 p,,,) = IPoolManager(s.POOL_MANAGER()).getSlot0(d.swapper.pairKey().toId());
        return uint256(p);
    }

    /// @dev The mint buys its floor share into IMD6900 at once (ETH -> $IMD at the mint, $IMD -> IMD6900 here), the
    ///      buy stopping once the pair pool's price has moved half the pool's fee; the rest waits, and anyone's
    ///      buyFloor in a later block takes it in the same way
    function test_MintBuysTheFloorAtOnce() public {
        deal(s.IMD(), minter, 70e18);
        uint256 p0 = _pairPrice();
        uint256 move = d.swapper.pairMoveBips();
        emit log_named_uint("pair fee / 2, bips", move);
        vm.prank(minter);
        d.minter.mintWithEth{value: 1 ether}(10, type(uint256).max);
        uint256 p1 = _pairPrice();
        assertGt(d.frens.reserve(), 0, "IMD6900 in the floor already");
        assertLe(p1 * p1 * 10_000 / (p0 * p0), 10_000 + move, "the price moved at most half the fee");
        uint256 waiting = d.frens.floorImd();
        emit log_named_decimal_uint("IMD6900 bought at the mint", d.frens.reserve(), 18);
        emit log_named_decimal_uint("$IMD still waiting", waiting, 18);
        vm.prank(minter);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        d.frens.buyFloor(0); // one buy a block
        vm.roll(block.number + 1);
        uint256 r = d.frens.reserve();
        vm.prank(address(0xA11CE)); // anyone
        d.frens.buyFloor(0);
        assertGt(d.frens.reserve(), r);
        assertLt(d.frens.floorImd(), waiting);
    }

    /// @dev Fees and royalties in ETH go ETH -> $IMD -> IMD6900 the same way
    function test_KeeperBuysEthIntoImd6900() public {
        vm.deal(address(d.frens), 0.01 ether);
        (, uint256 out) = d.minter.quoteFloorEth(0.01 ether);
        emit log_named_decimal_uint("IMD6900 for 0.01 ETH", out, 18);
        vm.roll(block.number + 1);
        vm.prank(address(0xA11CE)); // anyone
        d.frens.buyFloorWithEth(0.01 ether, 0);
        assertApproxEqRel(d.frens.reserve(), out, 0.06e18, "the quote, short of any price limit");
    }


    /// @dev IMD6900 counts at its dearest: the pool's price before any buy, then never above what the floor's buys paid
    function test_FloorRateIsTheDearest() public {
        uint256 spot = d.swapper.spotRate();
        (, uint256 tiny) = d.minter.quoteFloor(0.01e18);
        emit log_named_decimal_uint("IMD6900 per $IMD, the pool's price", spot, 18);
        emit log_named_decimal_uint("IMD6900 per $IMD, a small buy (fee included)", tiny * 100, 18);
        assertGt(spot, tiny * 100, "a buy pays the pool's fee");
        assertApproxEqRel(spot, tiny * 100, 0.12e18, "the pool's price, within the fee");
        assertEq(d.swapper.floorRate(), spot, "no buys yet: the pool's price");
        assertApproxEqRel(d.swapper.rateAverage(), spot, 1e12, "the average starts at the pool's price");
        deal(s.IMD(), minter, 70e18);
        vm.prank(minter);
        d.minter.mintWithEth{value: 1 ether}(10, type(uint256).max); // the mint buys the floor
        uint256 now_ = d.swapper.spotRate();
        assertLt(now_, spot, "the buy made IMD6900 dearer");
        assertEq(d.swapper.floorRate(), now_, "the lower of the price now and the average");
        // a block later the next buy moves the average 1/64 of the way to what it paid, no more
        uint256 avg = d.swapper.rateAverage();
        vm.roll(block.number + 1);
        if (d.frens.floorImd() == 0) {
            deal(s.IMD(), address(d.frens), IERC20(s.IMD()).balanceOf(address(d.frens)) + 1e18);
            stdstore.target(address(d.frens)).sig("floorImd()").checked_write(uint256(1e18));
        }
        d.frens.buyFloor(0);
        assertLt(d.swapper.rateAverage(), avg, "a buy paying more than the average pulls it down");
        assertGt(d.swapper.rateAverage(), avg - avg / 64, "by 1/64 of the way at most");
        assertLe(d.swapper.floorRate(), d.swapper.spotRate());
    }

    /// @dev Once fees lift the floor above the curve, the mint costs the floor: minting and selling straight back loses
    function test_MintAtTheFloorOnLivePools() public {
        deal(s.IMD(), minter, 70e18);
        vm.prank(minter);
        d.minter.mintWithEth{value: 1 ether}(10, type(uint256).max);
        vm.deal(address(d.frens), 0.05 ether); // fees and royalties
        vm.roll(block.number + 1);
        d.frens.buyFloorWithEth(0.05 ether, 0);
        uint256 curve;
        for (uint256 n = 10; n < 13; ++n) curve += d.frens.priceOf(n);
        uint256 q = d.frens.quote(3);
        emit log_named_decimal_uint("curve for 3", curve, 18);
        emit log_named_decimal_uint("quote for 3", q, 18);
        assertGt(q, curve, "the floor sets the price");
    }

}
