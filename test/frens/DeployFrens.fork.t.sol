// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployFrens} from "../../script/frens/DeployFrens.s.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrensRules} from "./FrensRules.sol";
import {FrensTimelockBatch} from "../../script/frens/FrensTimelockBatch.s.sol";
import {FrenWorkerGate} from "../../src/frens/FrenWorkerGate.sol";
import {Ownable} from "solady/auth/Ownable.sol";

interface IOwnerOf {
    function ownerOf(uint256) external view returns (address);
}

/// @notice On a mainnet fork: the deploy script's frens are wired, their rules are the tests' launch rules, sealed, and a
///         tier-0 minter gets only a pepe, a tier-3 one anything.
interface IPoolManagerFlash {
    function unlock(bytes calldata data) external returns (bytes memory);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
    function settle() external payable returns (uint256);
}

/// @dev Borrows $IMD from v4's PoolManager inside unlock (free) and tries to mint with the borrowed bag
contract FlashTier {
    IPoolManagerFlash constant PM = IPoolManagerFlash(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IMD6900Frens immutable frens;
    address immutable imd;

    constructor(IMD6900Frens f, address i) {
        (frens, imd) = (f, i);
    }

    function go() external {
        PM.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        PM.take(imd, address(this), 700e18); // tier 3, for one transaction
        IERC20(imd).approve(address(frens), type(uint256).max);
        frens.requestMint(69, type(uint256).max);
        PM.sync(imd);
        IERC20(imd).transfer(address(PM), 700e18);
        PM.settle();
        return "";
    }
}

contract DeployFrensForkTest is Test, FrensRules {
    using stdStorage for StdStorage;
    DeployFrens s;
    DeployFrens.Deployed d;
    address keeper = address(uint160(uint256(keccak256("frens keeper"))));
    uint256 constant RELAYER_KEY = uint256(keccak256("frens relayer key")); // a fresh key: well-known ones carry 7702 code on mainnet
    address relayer = vm.addr(RELAYER_KEY);

    function setUp() public {
        // a mainnet fork: MAINNET_RPC_URL; without one (an offline machine) these tests skip
        string memory rpc_ = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        s = new DeployFrens();
        d = s.deploy(address(s), keeper, relayer);
        vm.prank(address(s));
        d.gate.openPublic(); // these tests are the public mint's; the workers' window has its own below
    }

    /* ── the workers' window ─────────────────────────────────── */

    address constant DEPLOYER = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059; // the strategy's seat operator
    address stranger = address(uint160(uint256(keccak256("no identity.md"))));

    /// @dev A fresh deploy, opened: the window is on
    function _window() internal {
        d = s.deploy(address(s), keeper, relayer);
        vm.prank(address(s));
        d.frens.setMintOpen(true);
        assertTrue(d.gate.workerWindow());
        address imd = s.IMD();
        deal(imd, stranger, 100e18);
        vm.prank(stranger);
        IERC20(imd).approve(address(d.frens), type(uint256).max);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    /// @notice Once open, the frens are identity.md holders' only, one per NFT: a real holder of #1 on mainnet claims it
    ///         and mints; someone without one can't; an NFT counts once; anyone mints once the owner opens the public.
    function test_WorkersWindow() public {
        _window();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NoCredit.selector, 0));
        d.frens.requestMint(1, type(uint256).max);

        address holder = IOwnerOf(s.IDENTITY()).ownerOf(1);
        address imd = s.IMD();
        deal(imd, holder, 10e18);
        vm.startPrank(holder);
        IERC20(imd).approve(address(d.frens), type(uint256).max);
        d.gate.claim(_ids(1), holder);
        assertEq(d.gate.credits(holder), 1);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NoCredit.selector, 1));
        d.frens.requestMint(2, type(uint256).max); // one NFT, one fren
        d.frens.requestMint(1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.AlreadyClaimed.selector, 1));
        d.gate.claim(_ids(1), holder);
        vm.stopPrank();
        assertEq(d.frens.balanceOf(holder), 1);
        assertEq(d.gate.workerMinted(), 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NotYours.selector, 2));
        d.gate.claim(_ids(2), stranger);

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        d.gate.openPublic();
        vm.prank(address(s));
        d.gate.openPublic();
        vm.prank(stranger);
        d.frens.requestMint(1, type(uint256).max);
        assertEq(d.frens.balanceOf(stranger), 1, "the public mints once it's opened");
    }

    /// @notice The NFTs IMD6900 holds as IMD seats (#806, #1533, #1643): its seat operator claims them, for the strategy
    function test_TheStrategysSeatsClaimForIt() public {
        _window();
        uint256[] memory seats = new uint256[](3);
        (seats[0], seats[1], seats[2]) = (806, 1533, 1643);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NotYours.selector, 806));
        d.gate.claim(seats, stranger);
        address strategy = s.IMD6900();
        vm.prank(DEPLOYER);
        d.gate.claim(seats, strategy);
        assertEq(d.gate.credits(strategy), 3);
        vm.prank(stranger); // anyone may pay for the strategy's frens; the credits are its own
        d.frens.requestMintFor(strategy, 3, type(uint256).max);
        assertEq(d.frens.balanceOf(strategy), 3);
    }

    /// @notice The window closes for good once its 420 frens are minted
    function test_WindowEndsAt420() public {
        _window();
        stdstore.target(address(d.gate)).sig("workerMinted()").checked_write(uint256(420));
        assertFalse(d.gate.workerWindow());
        vm.prank(stranger);
        d.frens.requestMint(1, type(uint256).max);
        assertEq(d.frens.balanceOf(stranger), 1);
    }

    /// @notice Before the opening the owner mints the curve's first frens to the strategy (tier 3, by its identity.md
    ///         NFTs), paid in ETH through FrenMinter.buyImd; nobody else can mint yet. Logs what 150 cost in ETH.
    function test_FirstFrensToTheStrategy() public {
        d = s.deploy(address(s), keeper, relayer); // closed
        uint256 cost;
        for (uint256 n; n < 150; ++n) cost += d.frens.priceOf(n);
        cost += cost / 100;
        (address imd, address strategy) = (s.IMD(), s.IMD6900());
        address payer = address(uint160(uint256(keccak256("owner's wallet")))); // the deployer's ETH (a script contract can't take the refund)
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        uint256 eth = d.minter.buyImd{value: 1 ether}(cost);
        assertEq(IERC20(imd).balanceOf(payer), cost, "exactly the $IMD asked for");
        assertEq(payer.balance, 1 ether - eth, "the rest of the ETH came back");
        vm.prank(payer);
        IERC20(imd).transfer(address(s), cost);
        vm.startPrank(address(s));
        IERC20(imd).approve(address(d.frens), cost);
        uint256 a = d.frens.requestMintFor(strategy, 69, type(uint256).max);
        d.frens.requestMintFor(strategy, 69, type(uint256).max);
        d.frens.requestMintFor(strategy, 12, type(uint256).max);
        vm.stopPrank();
        emit log_named_decimal_uint("$IMD for the first 150 frens (+1%)", cost, 18);
        emit log_named_decimal_uint("ETH it took on POOL4", eth, 18);
        emit log_named_decimal_uint("$IMD left with the owner", IERC20(imd).balanceOf(address(s)), 18);
        assertEq(d.frens.balanceOf(strategy), 150);
        (, uint8 tier,,,,,,,,) = d.frens.requests(a);
        assertEq(tier, 3, "the strategy's identity.md NFTs make it tier 3");
        assertEq(address(d.minter).balance, 0);
        vm.prank(stranger);
        vm.expectRevert(IMD6900Frens.MintClosed.selector);
        d.frens.requestMint(1, type(uint256).max);
    }

    function test_Wired() public view {
        IMD6900Frens f = d.frens;
        assertEq(f.owner(), address(s));
        assertEq(f.keeper(), keeper);
        assertEq(f.relayer(), relayer);
        assertEq(f.renderer(), address(d.renderer));
        assertEq(f.swapper(), address(d.swapper));
        assertEq(f.workerGate(), address(d.gate));
        assertEq(d.gate.owner(), address(s), "the deployer opens the public mint, no timelock");
        assertEq(d.gate.frens(), address(f));
        assertEq(f.imdPayTo(), s.IMD_PAY_TO());
        assertTrue(f.traitsSealed());
        assertFalse(f.mintOpen());
        assertEq(d.renderer.faceLayers() + 30, d.renderer.layers().length);
    }

    /// @dev The script's rules are the launch rules every other test runs on.
    function test_RulesAreTheLaunchRules() public {
        IMD6900Frens ref = new IMD6900Frens(
            address(this), s.IMD(), s.IMD6900(), s.IDENTITY(), s.PERMIT2(), s.X402_PROXY(), s.IMD_PAY_TO(), keeper, relayer, d.prices
        );
        _rules(ref, [uint16(1598), 312, 312]);
        for (uint8 t; t < 8; ++t) {
            for (uint8 v; v < d.frens.valuesOf(t); ++v) {
                IMD6900Frens.Rule memory a = d.frens.ruleOf(t, v);
                IMD6900Frens.Rule memory b = ref.ruleOf(t, v);
                assertEq(a.cap, b.cap, "cap");
                assertEq(a.minTier, b.minTier, "min tier");
            }
        }
        assertEq(abi.encode(d.frens.pairRules()), abi.encode(ref.pairRules()));
    }

    function test_TiersShapeWhatCanMint() public view {
        uint24 pepe = _combo(PEPE, 0, 0, 0, 0, 0, 0, 0);
        uint24 mumu = _combo(MUMU, 0, 0, 0, 0, 0, 0, 0);
        uint24 goldMumu = _combo(MUMU, 0, 0, GOLD, 0, 0, 0, 0);
        uint24 saber = _combo(PEPE, LASER, 3, GOLD, 0, 2, 2, SABER);
        assertEq(d.frens.check(pepe, 0), 0);
        assertEq(d.frens.check(mumu, 0), 4);
        assertEq(d.frens.check(mumu, 2), 0);
        assertEq(d.frens.check(goldMumu, 2), 4);
        assertEq(d.frens.check(goldMumu, 3), 0);
        assertEq(d.frens.check(saber, 3), 0);
        assertEq(d.frens.check(_combo(MUMU, 0, 0, 0, 0, 1, 0, 0), 3), 1, "no hat on a mumu");
    }

    /// @dev A real tokenURI through the deployed renderer (what a marketplace reads).
    function test_TokenURIThroughTheDeployedRenderer() public view {
        string memory uri = d.renderer.tokenURI(1, _combo(BOBO, 10, 2, 1, 1, 0, 7, 15), 424242);
        assertEq(bytes(uri)[0], "d");
        assertGt(bytes(uri).length, 10_000);
    }

    /// @dev The minter's bag after paying sets the tier.
    function test_RequestReadsTheBag() public {
        vm.prank(address(s));
        d.frens.setMintOpen(true);
        address minter = address(uint160(uint256(keccak256("frens minter"))));
        deal(s.IMD(), minter, 69.69e18);
        vm.startPrank(minter);
        IERC20(s.IMD()).approve(address(d.frens), type(uint256).max);
        uint256 id = d.frens.requestMint(1, type(uint256).max);
        vm.stopPrank();
        (, uint8 tier,,,,,,,,) = d.frens.requests(id);
        assertEq(tier, 2);
    }

    /// @dev IMD6900 moves only through its pools or to and from distributors: selling a fren to the floor needs the
    ///      timelock batch that makes the frens contract one. Before it, recycle can't pay; after it, it does.
    function test_SellAtFloorNeedsTheBatch() public {
        vm.prank(address(s));
        d.frens.setMintOpen(true);
        address minter = address(uint160(uint256(keccak256("frens seller"))));
        deal(s.IMD(), minter, 10e18);
        vm.startPrank(minter);
        IERC20(s.IMD()).approve(address(d.frens), type(uint256).max);
        uint256 id = d.frens.requestMint(1, type(uint256).max);
        vm.stopPrank();
        uint24[] memory c = new uint24[](1);
        c[0] = _combo(PEPE, 2, 0, 0, 3, 0, 4, 1);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(RELAYER_KEY, d.frens.voucherDigest(id, c, "job", bytes32(0), deadline));
        d.frens.reveal(id, c, "job", bytes32(0), deadline, abi.encodePacked(r, s_, v), 1);
        assertGt(d.frens.reserve(), 0, "the mint bought IMD6900 into the floor");

        vm.prank(minter);
        vm.expectRevert(); // IMD6900 refuses to leave a contract that isn't a distributor
        d.frens.recycle(1);

        FrensTimelockBatch b = new FrensTimelockBatch();
        (address[] memory targets,, bytes[] memory datas) = b.batch(address(d.frens));
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(b.TIMELOCK());
            (bool ok,) = targets[i].call(datas[i]);
            assertTrue(ok, "a batch call failed");
        }
        (uint256 floor6900,) = d.frens.floorPerFren();
        vm.prank(minter);
        (uint256 paid,) = d.frens.recycle(1);
        assertEq(paid, floor6900);
        assertEq(IERC20(s.IMD6900()).balanceOf(minter), paid, "sold for the floor, in IMD6900");
        assertEq(d.frens.ownerOf(1), address(d.frens));
    }


    /// @dev A bag borrowed from v4's PoolManager (it holds ~245k $IMD and lends it free inside unlock) reaches no tier
    function test_FlashLoanedBagIsRefused() public {
        vm.prank(address(s));
        d.frens.setMintOpen(true);
        FlashTier f = new FlashTier(d.frens, s.IMD());
        deal(s.IMD(), address(f), 100e18); // enough to pay; the tier would come from the loan
        vm.expectRevert(IMD6900Frens.Flash.selector);
        f.go();
    }

}
