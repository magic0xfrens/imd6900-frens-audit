// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockToken, NoZeroToken, MockPermit2, MockSwapper} from "./IMD6900Frens.t.sol";
import {FrensRules} from "./FrensRules.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrenWorkerGate} from "../../src/frens/FrenWorkerGate.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev identity.md as the gate sees it: who holds each NFT
contract MockIdentity {
    mapping(uint256 => address) public ownerOf;
    function give(address to, uint256 from, uint256 n) external {
        for (uint256 i; i < n; ++i) ownerOf[from + i] = to;
    }
}

/// @dev IMD6900 as the gate sees it: its seat operator
contract MockSeatStrategy {
    address public seatOperator;
    constructor(address op) { seatOperator = op; }
}

/// @notice The workers' window: once the mint opens, its next 420 frens are identity.md holders' only, one per NFT.
contract FrenWorkerGateTest is Test, FrensRules {
    IMD6900Frens frens;
    MockToken imd;
    MockToken imd6900;
    MockToken idmd;
    MockSwapper swapper;
    address timelock = makeAddr("timelock");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    FrenWorkerGate gate;
    MockIdentity nfts;
    MockSeatStrategy strategy;
    address gateOwner = makeAddr("deployer");
    address seatOperator = makeAddr("seat operator");
    address carol = makeAddr("carol"); // no identity.md

    function setUp() public {
        imd = new MockToken("IMD");
        imd6900 = new NoZeroToken();
        idmd = new MockToken("IDMD");
        swapper = new MockSwapper(imd6900, imd);
        frens = new IMD6900Frens(
            timelock, address(imd), address(imd6900), address(idmd), address(new MockPermit2()), makeAddr("x402"), makeAddr("payTo"),
            makeAddr("keeper"), makeAddr("relayer"), _flatPrices()
        );
        vm.startPrank(timelock);
        _rules(frens, [uint16(1598), 312, 312]);
        frens.sealTraits();
        frens.setMintOpen(true);
        vm.stopPrank();
        for (uint256 i; i < 2; ++i) {
            address u = [alice, bob][i];
            imd.mint(u, 10_000e18);
            vm.prank(u);
            imd.approve(address(frens), type(uint256).max);
        }
        nfts = new MockIdentity();
        strategy = new MockSeatStrategy(seatOperator);
        gate = new FrenWorkerGate(gateOwner, address(frens), address(nfts), address(strategy));
        vm.prank(timelock);
        frens.setModules(address(swapper), address(gate));
        nfts.give(alice, 1, 3); // alice holds #1-#3
        nfts.give(address(strategy), 806, 1); // the strategy holds #806 as a seat
        idmd.mint(address(strategy), 3); // and identity.md NFTs make it tier 3
        imd.mint(carol, 1_000e18);
        vm.prank(carol);
        imd.approve(address(frens), type(uint256).max);
    }

    function _ids(uint256 from, uint256 n) internal pure returns (uint256[] memory x) {
        x = new uint256[](n);
        for (uint256 i; i < n; ++i) x[i] = from + i;
    }

    function test_WindowNeedsACreditPerFren() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NoCredit.selector, 0));
        frens.requestMint(1, type(uint256).max);
        vm.startPrank(alice);
        gate.claim(_ids(1, 2), alice);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NoCredit.selector, 2));
        frens.requestMint(3, type(uint256).max);
        frens.requestMint(2, type(uint256).max);
        vm.stopPrank();
        assertEq(gate.credits(alice), 0);
        assertEq(gate.workerMinted(), 2);
        assertEq(frens.balanceOf(alice), 2);
    }

    /// @dev A refused mint takes nothing: no $IMD, no fren, no credit
    function test_ARefusedMintTakesNothing() public {
        uint256 before = imd.balanceOf(carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NoCredit.selector, 0));
        frens.requestMint(1, type(uint256).max);
        assertEq(imd.balanceOf(carol), before);
        assertEq(frens.totalMinted(), 0);
    }

    function test_AnNftCountsOnce_whoeverHoldsItLater() public {
        vm.prank(alice);
        gate.claim(_ids(1, 1), alice);
        nfts.give(carol, 1, 1); // #1 sold to carol
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.AlreadyClaimed.selector, 1));
        gate.claim(_ids(1, 1), carol);
    }

    function test_OnlyTheHolderClaims() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NotYours.selector, 1));
        gate.claim(_ids(1, 1), carol);
        vm.expectRevert(FrenWorkerGate.BadClaim.selector);
        vm.prank(alice);
        gate.claim(_ids(1, 1), address(0));
    }

    /// @dev A holder can give their worker mints to the wallet they mint from (a cold wallet's NFTs, a hot wallet)
    function test_CreditsGoWhereTheHolderSays() public {
        vm.prank(alice);
        gate.claim(_ids(1, 3), bob);
        assertEq(gate.credits(bob), 3);
        assertEq(gate.credits(alice), 0);
        vm.prank(bob);
        frens.requestMint(3, type(uint256).max);
        assertEq(frens.balanceOf(bob), 3);
    }

    /// @dev The credit is the minter's, whoever pays (FrenMinter pays for ETH minters)
    function test_TheCreditIsTheMinters() public {
        vm.prank(alice);
        gate.claim(_ids(1, 1), alice);
        vm.prank(carol);
        frens.requestMintFor(alice, 1, type(uint256).max);
        assertEq(frens.balanceOf(alice), 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NoCredit.selector, 0));
        frens.requestMintFor(carol, 1, type(uint256).max);
    }

    function test_SeatOperatorClaimsTheStrategysNfts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NotYours.selector, 806));
        gate.claim(_ids(806, 1), alice);
        vm.prank(seatOperator);
        gate.claim(_ids(806, 1), address(strategy));
        assertEq(gate.credits(address(strategy)), 1);
    }

    function test_OnlyFrensSpends() public {
        vm.expectRevert(FrenWorkerGate.OnlyFrens.selector);
        gate.spend(carol, 1);
    }

    /// @dev The deployer opens the public mint at once (no timelock); nobody else can
    function test_OpenPublic() public {
        vm.prank(carol);
        vm.expectRevert(Ownable.Unauthorized.selector);
        gate.openPublic();
        vm.prank(timelock); // not even the frens' owner: the gate is the deployer's
        vm.expectRevert(Ownable.Unauthorized.selector);
        gate.openPublic();
        vm.prank(gateOwner);
        gate.openPublic();
        assertFalse(gate.workerWindow());
        vm.prank(carol);
        frens.requestMint(1, type(uint256).max);
        assertEq(frens.balanceOf(carol), 1);
    }

    /// @dev 420 worker frens, then the window is over for good
    function test_WindowClosesAfter420() public {
        nfts.give(bob, 1000, 420);
        vm.startPrank(bob);
        gate.claim(_ids(1000, 420), bob);
        for (uint256 i; i < 6; ++i) frens.requestMint(69, type(uint256).max);
        assertTrue(gate.workerWindow(), "414 so far");
        frens.requestMint(6, type(uint256).max);
        vm.stopPrank();
        assertEq(gate.workerMinted(), 420);
        assertFalse(gate.workerWindow());
        vm.prank(carol);
        frens.requestMint(1, type(uint256).max);
        assertEq(frens.balanceOf(carol), 1, "the public's now");
    }

    /// @dev Before the opening only the owner mints (the strategy's first frens), without worker credits
    function test_OwnerMintsBeforeTheOpening() public {
        vm.prank(timelock);
        frens.setMintOpen(false);
        vm.prank(carol);
        vm.expectRevert(IMD6900Frens.MintClosed.selector);
        frens.requestMint(1, type(uint256).max);
        imd.mint(timelock, 100e18);
        vm.startPrank(timelock);
        imd.approve(address(frens), type(uint256).max);
        frens.requestMintFor(address(strategy), 69, type(uint256).max);
        vm.stopPrank();
        assertEq(frens.balanceOf(address(strategy)), 69);
        assertEq(gate.workerMinted(), 0, "the window starts at the opening");
    }

    /// @dev No gate: no window (the timelock can turn it off)
    function test_NoGateNoWindow() public {
        vm.prank(timelock);
        frens.setModules(address(swapper), address(0));
        vm.prank(carol);
        frens.requestMint(1, type(uint256).max);
        assertEq(frens.balanceOf(carol), 1);
    }
}
