// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IMD6900Frens, IFrenSwapper, ICreatorToken, ICreatorTokenLegacy} from "../../src/frens/IMD6900Frens.sol";
import {FrensRules} from "./FrensRules.sol";
import {FrenMinter} from "../../src/frens/FrenMinter.sol";
import {FrenArt} from "../../src/frens/FrenRenderer.sol";

contract MockToken is ERC20 {
    string internal n;
    constructor(string memory n_) { n = n_; }
    function name() public view override returns (string memory) { return n; }
    function symbol() public view override returns (string memory) { return n; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev Like IMD6900: a transfer of nothing reverts
contract NoZeroToken is MockToken {
    constructor() MockToken("IMD6900") {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(amount != 0, "zero");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(amount != 0, "zero");
        return super.transferFrom(from, to, amount);
    }
}

/// @dev v4's PoolManager as the frens see it: is it unlocked right now (transient slot Lock.IS_UNLOCKED_SLOT)?
contract MockPoolManager {
    bool unlocked;
    function setUnlocked(bool u) external { unlocked = u; }
    function exttload(bytes32) external view returns (bytes32) { return unlocked ? bytes32(uint256(1)) : bytes32(0); }
}

contract MockPermit2 {
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;
    function DOMAIN_SEPARATOR() external pure returns (bytes32) { return keccak256("permit2"); }
    function spend(address owner, uint256 nonce) external { nonceBitmap[owner][nonce >> 8] |= 1 << (nonce & 0xff); }
}

/// @dev Pays out `rate` IMD6900 per unit in, minted fresh.
contract MockSwapper is IFrenSwapper {
    MockToken public immutable out;
    MockToken public immutable imdToken;
    uint256 public rate = 70_000;
    uint256 public spendBps = 10_000; // how much of a buy the price limit lets through
    constructor(MockToken o, MockToken i) { out = o; imdToken = i; }
    function setRate(uint256 r) external { rate = r; }
    function setSpend(uint256 b) external { spendBps = b; }
    uint256 public floorRateSet; // 0: the swap's own rate
    function setFloorRate(uint256 r) external { floorRateSet = r; }
    function floorRate() external view returns (uint256) { return floorRateSet != 0 ? floorRateSet : rate * 1e18; }
    function imdToImd6900(uint256 imdIn, uint256, address to) external returns (uint256 got) {
        uint256 spend = imdIn * spendBps / 10_000;
        imdToken.transferFrom(msg.sender, address(this), spend); // pulls what it spends, as FrenSwapper does
        got = spend * rate; out.mint(to, got);
    }
    function ethToImd6900(uint256, address to) external payable returns (uint256 got) {
        got = msg.value * rate * 3000; out.mint(to, got);
    }
}

/// @dev A transfer validator that lets only `allowed` move frens between holders (or the holder itself, OTC)
contract RevertingSwapper is IFrenSwapper {
    function floorRate() external pure returns (uint256) { return 70_000e18; }
    function imdToImd6900(uint256, uint256, address) external pure returns (uint256) { revert("pool closed"); }
    function ethToImd6900(uint256, address) external payable returns (uint256) { revert("pool closed"); }
}

contract MockValidator {
    address public allowed;
    uint16 public tokenType;
    error Blocked();
    function allow(address a) external { allowed = a; }
    function setTokenTypeOfCollection(address, uint16 t) external { tokenType = t; }
    function validateTransfer(address caller, address from, address, uint256) external view {
        if (caller != from && caller != allowed) revert Blocked();
    }
}

contract MockRenderer {
    function tokenURI(uint256 id, uint24 combo, uint256) external pure returns (string memory) {
        return string.concat("fren:", vm_toString(id), ":", vm_toString(combo));
    }
    function pendingURI(uint256 id) external pure returns (string memory) {
        return string.concat("unrevealed:", vm_toString(id));
    }
    function vm_toString(uint256 v) internal pure returns (string memory s) {
        if (v == 0) return "0";
        while (v > 0) { s = string.concat(string(abi.encodePacked(bytes1(uint8(48 + v % 10)))), s); v /= 10; }
    }
}

contract IMD6900FrensTest is Test, FrensRules {
    IMD6900Frens frens;
    MockToken imd;
    MockToken imd6900;
    MockToken idmd; // identity.md: balanceOf is all the frens read
    MockPermit2 permit2;
    MockSwapper swapper;
    address timelock = makeAddr("timelock");
    address keeper = makeAddr("keeper");
    uint256 relayerKey = 0xA11CE;
    address relayer;
    address payTo = makeAddr("imdPayTo");
    address proxy = makeAddr("x402Proxy");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 minted; // a counter for fresh common pepes

    function setUp() public {
        imd = new MockToken("IMD");
        imd6900 = new NoZeroToken();
        idmd = new MockToken("IDMD");
        permit2 = new MockPermit2();
        swapper = new MockSwapper(imd6900, imd);
        relayer = vm.addr(relayerKey);
        frens = _deploy([uint16(1598), 312, 312]);
        for (uint256 i; i < 2; ++i) {
            address u = [alice, bob][i];
            imd.mint(u, 10_000e18); // tier 3 by $IMD
            vm.prank(u);
            imd.approve(address(frens), type(uint256).max);
        }
    }

    function _deploy(uint16[3] memory chars) internal returns (IMD6900Frens f) {
        f = new IMD6900Frens(timelock, address(imd), address(imd6900), address(idmd), address(permit2), proxy, payTo, keeper, relayer, _flatPrices());
        vm.startPrank(timelock);
        _rules(f, chars);
        f.sealTraits();
        f.setModules(address(swapper), address(0));
        f.setMintOpen(true);
        vm.stopPrank();
    }

    /// @dev A fresh common pepe each time: 12 faces x 6 shirts x 10 backgrounds
    function _common() internal returns (uint24) {
        uint256 i = minted++;
        return _combo(PEPE, uint8(i % 12), 0, 0, uint8((i / 12) % 6), 0, uint8((i / 72) % 10), 0);
    }

    function _one(uint24 combo) internal pure returns (uint24[] memory a) {
        a = new uint24[](1);
        a[0] = combo;
    }

    function _sign(IMD6900Frens f, uint256 key, uint256 id, uint24 combo, uint256 deadline) internal view returns (bytes memory) {
        return _signMany(f, key, id, _one(combo), deadline);
    }

    function _signMany(IMD6900Frens f, uint256 key, uint256 id, uint24[] memory combos, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(key, f.voucherDigest(id, combos, "job-1", keccak256("out"), deadline));
        return abi.encodePacked(r, s_, v);
    }

    function _request(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = frens.requestMint(1, type(uint256).max);
    }

    function _quote() internal view returns (IMD6900Frens.Quote memory q) {
        q = IMD6900Frens.Quote("https://api.imd.fun/requests/x", bytes32("scope"), "q1", bytes32("qh"), bytes32("ph"), "job.open", block.timestamp + 600);
    }

    function _approve(uint256 id) internal {
        vm.prank(keeper);
        frens.approveJob(id, id, block.timestamp + 600, _quote());
    }

    /// @dev A request's first fren
    function _first(uint256 id) internal view returns (uint256) {
        (,,,,,,, uint32 first,,) = frens.requests(id);
        return first;
    }

    /// @dev The relayer's voucher reveals a one-fren request's fren
    function _reveal(uint256 id, uint24 combo) internal returns (uint256 tokenId) {
        uint256 d = block.timestamp + 1 hours;
        frens.reveal(id, _one(combo), "job-1", keccak256("out"), d, _sign(frens, relayerKey, id, combo, d), 1);
        return _first(id);
    }

    function _revealReverts(uint256 id, uint24 combo, bytes memory err) internal {
        uint256 d = block.timestamp + 1 hours;
        bytes memory sig = _sign(frens, relayerKey, id, combo, d);
        vm.expectRevert(err);
        frens.reveal(id, _one(combo), "job-1", keccak256("out"), d, sig, 1);
    }

    /// @dev Mint one, the keeper approves its job, the relayer's voucher reveals it as a fresh common pepe
    function _mintOne(address who) internal returns (uint256 tokenId) {
        uint256 id = _request(who);
        _approve(id);
        tokenId = _reveal(id, _common());
    }

    /// @dev A wallet holding exactly this much of each
    function _holder(string memory label, uint256 imdBal, uint256 imd6900Bal, uint256 nfts) internal returns (address w) {
        w = makeAddr(label);
        imd.mint(w, imdBal + 0.69e18); // what they keep after paying the mint
        if (imd6900Bal > 0) imd6900.mint(w, imd6900Bal);
        if (nfts > 0) idmd.mint(w, nfts);
        vm.prank(w);
        imd.approve(address(frens), type(uint256).max);
    }

    /* ── the traits ─────────────────────────────────────────────── */

    function test_MintNeedsSealedTraits() public {
        IMD6900Frens f = new IMD6900Frens(timelock, address(imd), address(imd6900), address(idmd), address(permit2), proxy, payTo, keeper, relayer, _flatPrices());
        vm.prank(timelock);
        f.setMintOpen(true);
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.TraitsNotSealed.selector);
        f.requestMint(1, type(uint256).max);
    }

    function test_SealNeedsEveryTraitAndTheSupply() public {
        IMD6900Frens f = new IMD6900Frens(timelock, address(imd), address(imd6900), address(idmd), address(permit2), proxy, payTo, keeper, relayer, _flatPrices());
        vm.startPrank(timelock);
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        f.sealTraits(); // nothing set
        _rules(f, [uint16(1600), 312, 312]); // 2224 characters
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        f.sealTraits();
        (uint16[] memory c, uint8[] memory t) = _fill(3, 0, 2);
        (c[0], c[1], c[2], t[0]) = (1598, 312, 312, 0);
        f.setTraitRules(0, c, t);
        f.sealTraits();
        vm.stopPrank();
        assertTrue(f.traitsSealed());
    }

    function test_RulesAreFrozenOnceSealed() public {
        (uint16[] memory c, uint8[] memory t) = _fill(3, 1000, 0);
        vm.startPrank(timelock);
        vm.expectRevert(IMD6900Frens.TraitsAreSealed.selector);
        frens.setTraitRules(0, c, t);
        vm.expectRevert(IMD6900Frens.TraitsAreSealed.selector);
        frens.addPairRule(IMD6900Frens.PairRule(0, PEPE, 3, GOLD, 3));
        vm.stopPrank();
    }

    /// @dev Unsold rares can be let down to lower tiers, never raised
    function test_MinTierOnlyGoesDown() public {
        vm.startPrank(timelock);
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        frens.lowerMinTier(0, MUMU, 3); // up
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        frens.lowerMinTier(0, MUMU, 2); // same
        frens.lowerMinTier(0, MUMU, 1);
        vm.stopPrank();
        assertEq(frens.ruleOf(0, MUMU).minTier, 1);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        frens.lowerMinTier(0, BOBO, 0);
    }

    /* ── tiers ──────────────────────────────────────────────────── */

    function test_TierIsTheBestOfTheBag() public {
        assertEq(frens.tierOf(makeAddr("nobody")), 0);
        imd.mint(makeAddr("i1"), 6.9e18);
        assertEq(frens.tierOf(makeAddr("i1")), 1);
        imd.mint(makeAddr("i2"), 69e18);
        assertEq(frens.tierOf(makeAddr("i2")), 2);
        imd.mint(makeAddr("i3"), 690e18);
        assertEq(frens.tierOf(makeAddr("i3")), 3);
        imd6900.mint(makeAddr("x2"), 6_900_000e18);
        assertEq(frens.tierOf(makeAddr("x2")), 2);
        idmd.mint(makeAddr("nft"), 1);
        assertEq(frens.tierOf(makeAddr("nft")), 3, "one identity.md is tier 3");
        imd.mint(makeAddr("x2"), 690e18);
        assertEq(frens.tierOf(makeAddr("x2")), 3, "the best asset counts");
    }

    function test_TierThresholdsOwnerOnlyAndOrdered() public {
        uint256[3] memory a = [uint256(1e18), 2e18, 3e18];
        uint256[3] memory bad = [uint256(3e18), 2e18, 1e18];
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        frens.setTiers(a, a, a);
        vm.startPrank(timelock);
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        frens.setTiers(bad, a, a);
        frens.setTiers(a, a, a);
        vm.stopPrank();
        assertEq(frens.imdTier(2), 3e18);
    }

    /* ── the mint: frens at once, unrevealed ────────────────────── */

    function test_MintMintsAtOnce_unrevealed() public {
        MockRenderer mr = new MockRenderer();
        vm.prank(timelock);
        frens.setRoles(address(0), address(0), address(0), address(mr));
        uint256 id = _request(alice);
        assertEq(frens.ownerOf(1), alice, "hers from the mint");
        assertEq(frens.totalMinted(), 1);
        assertEq(frens.seedOf(1), 0, "not revealed");
        assertEq(frens.tokenURI(1), "unrevealed:1");
        assertEq(imd.balanceOf(address(frens)), 0.5e18, "the job's part waits here");
        assertEq(frens.jobBudget(), 0.5e18);
        assertEq(frens.reserve(), 0.19e18 * 70_000, "the floor's part, bought into IMD6900 at once");
        (address minter, uint8 tier,,, uint8 count, uint8 revealed, uint8 jobs, uint32 first,,) = frens.requests(id);
        assertEq(minter, alice);
        assertEq(tier, 3);
        assertEq(count, 1);
        assertEq(revealed, 0);
        assertEq(jobs, 1, "its first job is paid for");
        assertEq(first, 1);
    }

    /// @dev The tier counts what's left after paying the mint
    function test_TierCountsWhatIsLeftAfterPaying() public {
        address keeps = _holder("keeps", 6.9e18, 0, 0); // holds 7.59, keeps 6.9
        address short = makeAddr("short");
        imd.mint(short, 6.9e18); // keeps 6.21
        vm.prank(short);
        imd.approve(address(frens), type(uint256).max);
        (, uint8 t1,,,,,,,,) = frens.requests(_request(keeps));
        (, uint8 t0,,,,,,,,) = frens.requests(_request(short));
        assertEq(t1, 1);
        assertEq(t0, 0);
    }

    /// @dev Below mumu and bobo a fren can only reveal as a pepe: no mint once no pepe is left for it
    function test_LowTierRequestsNeedAPepeLeft() public {
        frens = _deploy([uint16(2), 1110, 1110]);
        address low = _holder("low", 0, 0, 0);
        imd.mint(low, 10e18);
        vm.prank(low);
        imd.approve(address(frens), type(uint256).max);
        _request(low);
        _request(low);
        vm.prank(low);
        vm.expectRevert(IMD6900Frens.SoldOut.selector);
        frens.requestMint(1, type(uint256).max);
        vm.startPrank(alice); // tier 3 can still mint: mumu and bobo are left
        imd.approve(address(frens), type(uint256).max);
        frens.requestMint(1, type(uint256).max);
        vm.stopPrank();
    }

    function test_NoRequestForNobody() public {
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        frens.requestMintFor(address(0), 1, type(uint256).max);
    }

    /// @dev A bag borrowed from v4's PoolManager (free inside unlock) never reaches a tier
    function test_NoTierInsideAFlashLoan() public {
        MockPoolManager pm = new MockPoolManager();
        vm.etch(0x000000000004444c5dc75cB358380D2e3dE08A90, address(pm).code);
        MockPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90).setUnlocked(true);
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.Flash.selector);
        frens.requestMint(1, type(uint256).max);
        MockPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90).setUnlocked(false);
        _request(alice);
    }

    /* ── the reveal ─────────────────────────────────────────────── */

    function test_RevealShowsTheFren() public {
        MockRenderer mr = new MockRenderer();
        vm.prank(timelock);
        frens.setRoles(address(0), address(0), address(0), address(mr));
        uint256 id = _request(alice);
        _approve(id);
        uint24 c = _combo(MUMU, 3, 1, 0, 2, 0, 7, SABER);
        assertEq(_reveal(id, c), 1);
        assertEq(frens.ownerOf(1), alice);
        assertEq(frens.comboOf(1), c);
        assertTrue(frens.seedOf(1) != 0);
        assertTrue(frens.taken(c));
        assertEq(frens.ruleOf(0, MUMU).minted, 1);
        assertEq(frens.ruleOf(7, SABER).minted, 1);
        assertEq(frens.tokenURI(1), string.concat("fren:1:", vm.toString(uint256(c))), "revealed");
        (,,,,, uint8 revealed,,,,) = frens.requests(id);
        assertEq(revealed, 1);
    }

    function test_RevealNeedsTheRelayersVoucher() public {
        uint256 id = _request(alice);
        uint24 c = _common();
        uint256 d = block.timestamp + 1 hours;
        bytes memory forged = _sign(frens, 0xB0B, id, c, d);
        vm.expectRevert(IMD6900Frens.BadVoucher.selector);
        frens.reveal(id, _one(c), "job-1", keccak256("out"), d, forged, 1);
        bytes memory real = _sign(frens, relayerKey, id, c, d);
        vm.expectRevert(IMD6900Frens.BadVoucher.selector);
        frens.reveal(id, _one(c + 1), "job-1", keccak256("out"), d, real, 1); // a different fren than the voucher names
        vm.expectRevert(IMD6900Frens.BadVoucher.selector);
        frens.reveal(id, _one(c), "job-2", keccak256("out"), d, real, 1); // or a different job
        frens.reveal(id, _one(c), "job-1", keccak256("out"), d, real, 1);
    }

    function test_VouchersExpire() public {
        uint256 id = _request(alice);
        uint24 c = _common();
        uint256 d = block.timestamp + 1 hours;
        bytes memory sig = _sign(frens, relayerKey, id, c, d);
        vm.warp(d + 1);
        vm.expectRevert(IMD6900Frens.BadVoucher.selector);
        frens.reveal(id, _one(c), "job-1", keccak256("out"), d, sig, 1);
    }

    /// @dev No window to miss: a fren reveals whenever its job lands, a month later too
    function test_RevealsWhenever() public {
        uint256 id = _request(alice);
        vm.warp(block.timestamp + 30 days);
        _reveal(id, _common());
    }

    function test_OneRevealPerFren() public {
        uint256 id = _request(alice);
        _reveal(id, _common());
        _revealReverts(id, _common(), abi.encodeWithSelector(IMD6900Frens.BadRequest.selector));
    }

    function test_EveryFrenIsOneOfAKind() public {
        uint256 a = _request(alice);
        uint256 b = _request(bob);
        uint24 c = _common();
        _reveal(a, c);
        _revealReverts(b, c, abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(2)));
    }

    function test_TraitCapsHold() public {
        for (uint256 i; i < 56; ++i) {
            uint256 id = _request(alice);
            _reveal(id, _combo(PEPE, LASER, uint8(i % 3), 0, uint8((i / 3) % 6), 0, uint8(i / 18), 0));
        }
        assertEq(frens.ruleOf(1, LASER).minted, 56);
        uint256 last = _request(alice);
        _revealReverts(last, _combo(PEPE, LASER, 0, 1, 0, 0, 0, 0), abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(3)));
    }

    function test_RareTraitsNeedTheTier() public {
        address low = _holder("low", 0, 0, 0);
        uint256 id = _request(low);
        bytes memory tooLow = abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(4));
        _revealReverts(id, _combo(MUMU, 0, 0, 0, 0, 0, 0, 0), tooLow); // tier 2
        _revealReverts(id, _combo(PEPE, LASER, 0, 0, 0, 0, 0, 0), tooLow); // tier 3
        _revealReverts(id, _combo(PEPE, 0, 0, GOLD, 0, 0, 0, 0), tooLow); // tier 1
        _revealReverts(id, _combo(PEPE, 0, 0, 0, 0, 1, 0, 0), tooLow); // a hat, tier 1
        _revealReverts(id, _combo(PEPE, 0, 0, 0, 0, 0, 0, 2), tooLow); // a tier-1 item
        _reveal(id, _combo(PEPE, 0, 0, 0, 0, 0, 0, 1)); // a common item: fine
    }

    function test_PairRules() public {
        address mid = _holder("mid", 69e18, 0, 0); // tier 2
        uint256 a = _request(mid);
        _revealReverts(a, _combo(MUMU, 0, 0, GOLD, 0, 0, 0, 0), abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(4)));
        _reveal(a, _combo(MUMU, 0, 0, 1, 0, 0, 0, 0)); // a black coat: tier 2 is enough
    }

    /// @dev The tier is the mint's: selling the bag after doesn't take the rare fren away, buying one after doesn't help
    function test_TierIsTheMints() public {
        address seller = _holder("seller", 690e18, 0, 0); // tier 3 at the mint
        uint256 a = _request(seller);
        vm.prank(seller);
        imd.transfer(bob, 690e18); // sells it all
        _reveal(a, _combo(PEPE, LASER, 0, 0, 0, 0, 0, 0));

        address late = _holder("late", 0, 0, 0); // tier 0 at the mint
        uint256 b = _request(late);
        idmd.mint(late, 1); // an identity.md after minting
        _revealReverts(b, _combo(MUMU, 0, 0, 0, 0, 0, 0, 0), abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(4)));
    }

    function test_OnlyRealFrens() public {
        uint256 id = _request(alice);
        bytes memory notAFren = abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(1));
        _revealReverts(id, _combo(MUMU, 0, 0, 0, 0, 1, 0, 0), notAFren); // hats fit only the pepe
        _revealReverts(id, _combo(PEPE, 13, 0, 0, 0, 0, 0, 0), notAFren); // no face 13
        _revealReverts(id, _combo(3, 0, 0, 0, 0, 0, 0, 0), notAFren); // no character 3
        _revealReverts(id, _combo(PEPE, 0, 0, 0, 6, 0, 0, 0), notAFren); // no shirt 6
        _revealReverts(id, uint24(1 << 23), notAFren); // the spare bit
    }

    /// @dev Anyone may send the reveal, and it reveals the fren wherever it is now
    function test_RevealFollowsTheFren() public {
        uint256 id = _request(alice);
        vm.prank(alice);
        frens.transferFrom(alice, bob, 1); // sold unrevealed
        vm.prank(makeAddr("relayer's sender"));
        uint256 t = _reveal(id, _common());
        assertEq(frens.ownerOf(t), bob);
        assertTrue(frens.seedOf(t) != 0);
    }

    /// @dev A job the request paid for but never needed (revealed another way) feeds the floor
    function test_UnusedJobFeedsTheFloor() public {
        uint256 id = _request(alice);
        _reveal(id, _common()); // no job approved for it
        assertEq(frens.jobBudget(), 0);
        assertEq(_floorValue(), 0.69e18, "the job's 0.50 joins the 0.19 in the floor");
    }

    /* ── the job, and paying another when one didn't land ───────── */

    function test_KeeperApprovesTheJobPaidFor() public {
        uint256 id = _request(alice);
        vm.prank(keeper);
        (bytes32 pd, bytes32 qd) = frens.approveJob(id, 42, block.timestamp + 600, _quote());
        assertEq(frens.isValidSignature(pd, ""), bytes4(0x1626ba7e));
        assertEq(frens.isValidSignature(qd, ""), bytes4(0x1626ba7e));
        assertEq(frens.isValidSignature(keccak256("anything else"), ""), bytes4(0xffffffff));
        assertEq(imd.allowance(address(frens), address(permit2)), 0.5e18);
        vm.prank(keeper);
        vm.expectRevert(IMD6900Frens.BadJob.selector); // the payment can still be taken
        frens.approveJob(id, 43, block.timestamp + 600, _quote());
    }

    /// @dev The payment approved is pinned to IMD's payee: the same nonce and deadline to another payee is another one
    function test_JobPaymentIsPinnedToImdsPayee() public {
        uint256 a = _request(alice);
        uint256 b = _request(bob);
        uint256 d = block.timestamp + 600;
        vm.prank(keeper);
        (bytes32 d1,) = frens.approveJob(a, 7, d, _quote());
        vm.prank(timelock);
        frens.setRoles(address(0), address(0), bob, address(0));
        vm.prank(keeper);
        (bytes32 d2,) = frens.approveJob(b, 7, d, _quote());
        assertTrue(d1 != d2);
    }

    function test_KeeperCannotApproveLongLivedPayments() public {
        uint256 id = _request(alice);
        vm.prank(keeper);
        vm.expectRevert(IMD6900Frens.BadJob.selector);
        frens.approveJob(id, 1, block.timestamp + 2 hours, _quote());
    }

    function test_NobodyElseApprovesJobs() public {
        uint256 id = _request(alice);
        vm.prank(bob);
        vm.expectRevert(IMD6900Frens.NotKeeper.selector);
        frens.approveJob(id, 1, block.timestamp + 600, _quote());
    }

    /// @dev A payment IMD never took and can't any more is undone, and its job money pays the next approval
    function test_LapsedPaymentIsUsedAgain() public {
        uint256 id = _request(alice);
        vm.prank(keeper);
        (bytes32 pd,) = frens.approveJob(id, 42, block.timestamp + 600, _quote());
        vm.warp(block.timestamp + 601);
        vm.prank(keeper);
        frens.approveJob(id, 43, block.timestamp + 600, _quote());
        assertEq(frens.isValidSignature(pd, ""), bytes4(0xffffffff), "the lapsed one can't be taken");
        assertEq(imd.allowance(address(frens), address(permit2)), 0.5e18, "one payment's worth");
        assertEq(frens.jobBudget(), 0);
    }

    /// @dev A job that ran and didn't land reveals nothing, refunds nothing: another needs paying, by anyone
    function test_FailedJob_payAnother() public {
        uint256 id = _request(alice);
        _approve(id);
        permit2.spend(address(frens), id); // IMD took it: the job ran
        vm.warp(block.timestamp + 601);
        vm.prank(keeper);
        vm.expectRevert(IMD6900Frens.BadJob.selector); // no job paid for
        frens.approveJob(id, 99, block.timestamp + 600, _quote());
        uint256 before = imd.balanceOf(bob);
        vm.prank(bob); // holds nothing of it: anyone may pay
        frens.retryJob(id);
        assertEq(before - imd.balanceOf(bob), 0.5e18);
        vm.prank(bob);
        vm.expectRevert(IMD6900Frens.BadJob.selector); // one waiting at a time
        frens.retryJob(id);
        vm.prank(keeper);
        frens.approveJob(id, 99, block.timestamp + 600, _quote());
        assertEq(frens.ownerOf(1), alice, "still alice's, unrevealed");
        _reveal(id, _common());
    }

    /// @dev A retry paid while the last job landed after all: its 0.50 feeds the floor
    function test_UnneededRetryFeedsTheFloor() public {
        uint256 id = _request(alice);
        _approve(id);
        permit2.spend(address(frens), id);
        vm.prank(bob);
        frens.retryJob(id);
        uint256 waiting = frens.floorImd();
        _reveal(id, _common());
        assertEq(frens.floorImd(), waiting + 0.5e18);
        assertEq(frens.jobBudget(), 0);
        vm.prank(bob);
        vm.expectRevert(IMD6900Frens.BadJob.selector); // nothing left to reveal
        frens.retryJob(id);
    }

    /* ── the mint never costs less than the floor ─────────────────── */

    /// @dev Fees and royalties raise the floor above the curve: the mint then costs the floor, so minting and selling
    ///      straight back to it never pays (the seller gets the floor less their share of the job)
    function test_MintNeverBelowTheFloor() public {
        _floorOf(4);
        (bool ok,) = address(frens).call{value: 0.1 ether}(""); // royalties
        assertTrue(ok);
        vm.roll(vm.getBlockNumber() + 1);
        frens.buyFloorWithEth(0.1 ether, 0); // the floor jumps far above the 0.69 curve
        uint256 rate = swapper.floorRate();
        (uint256 f6900, uint256 fImd) = frens.floorPerFren();
        uint256 value = fImd + f6900 * 1e18 / rate;
        assertGt(value, 0.69e18, "the floor is above the curve now");
        assertApproxEqAbs(frens.quote(1), value, 4, "one fren: the floor");
        assertApproxEqAbs(frens.quote(3), 3 * value, 12);
        // mint at that price and sell straight back: no profit
        uint256 imdBefore = imd.balanceOf(bob);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        frens.requestMint(1, type(uint256).max);
        uint256 paid = imdBefore - imd.balanceOf(bob);
        vm.prank(bob);
        (uint256 got6900, uint256 gotImd) = frens.recycle(5);
        uint256 back = gotImd + got6900 * 1e18 / rate;
        assertLt(back, paid, "selling straight back returns less than the mint cost");
        (uint256 a6900, uint256 aImd) = frens.floorPerFren();
        assertApproxEqAbs(aImd + a6900 * 1e18 / rate, value - 0.5e18 / 5, 1e12, "the others keep the floor, less a fifth of one job");
    }

    /// @dev IMD6900 counts at its dearest: a lower rate (IMD6900 dearer) makes the floor, and the mint, cost more
    function test_DearerImd6900RaisesTheFloorPrice() public {
        _floorOf(4);
        uint256 q = frens.quote(1);
        swapper.setFloorRate(10_000e18); // IMD6900 7x dearer than the swaps paid
        assertGt(frens.quote(1), q);
    }

    /// @dev Below the floor the curve sets the price, as before
    function test_CurveWhileAboveTheFloor() public {
        _floorOf(2);
        assertEq(frens.quote(10), 6.9e18, "ten at the flat test curve");
    }

    /* ── audit fixes (2026-10-05) ───────────────────────────────── */

    /// @dev Every fren is minted at once, so every one shares the floor from its mint: no holder can take the floor
    ///      money of frens still waiting for their reveal
    function test_UnrevealedFrensShareTheFloor() public {
        _mintOne(alice); // 1 fren, 0.19 in the floor
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        frens.requestMint(10, type(uint256).max); // 10 unrevealed, 6.40 more in the floor
        uint256 total = frens.reserve();
        (uint256 f,) = frens.floorPerFren();
        assertEq(f, total / 11, "eleven frens share it");
        vm.prank(alice);
        (uint256 paid,) = frens.recycle(1);
        assertEq(paid, total / 11, "one share of eleven");
        (uint256 after_,) = frens.floorPerFren();
        assertApproxEqAbs(after_, f, 1, "bob's ten frens keep their share");
    }

    /// @dev An unrevealed fren sells at the floor too, and still reveals later, in the treasury
    function test_UnrevealedFrenSellsAtTheFloor() public {
        uint256 id = _request(alice);
        vm.prank(alice);
        (uint256 paid,) = frens.recycle(1);
        assertGt(paid, 0);
        assertEq(frens.ownerOf(1), address(frens));
        _reveal(id, _common());
        assertTrue(frens.seedOf(1) != 0);
    }

    /// @dev With every fren in the treasury, buying one back costs twice the whole floor, never nothing
    function test_EmptyWorldFloorIsNotFree() public {
        _floorOf(1);
        vm.prank(alice);
        frens.recycle(1); // the only fren, back in the treasury
        (bool ok,) = address(frens).call{value: 0.1 ether}(""); // fees keep coming
        assertTrue(ok);
        vm.roll(vm.getBlockNumber() + 1);
        frens.buyFloorWithEth(0.1 ether, 0);
        (uint256 f,) = frens.floorPerFren();
        assertEq(f, frens.reserve(), "one share: all of it");
        imd6900.mint(bob, 1e30);
        vm.startPrank(bob);
        imd6900.approve(address(frens), type(uint256).max);
        (uint256 paid,) = frens.buyTreasury(1, type(uint256).max, type(uint256).max);
        vm.stopPrank();
        assertEq(paid, 2 * f);
    }

    /// @dev The swapper may pull only the buy at hand, never the job budget or the rest of the floor
    function test_SwapperMayPullOnlyTheBuy() public {
        swapper.setSpend(5_000);
        _mintOne(alice);
        assertLe(imd.allowance(address(frens), address(swapper)), 0.19e18, "at most this buy's");
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(timelock);
        frens.setModules(address(0xbad), address(0));
        assertEq(imd.allowance(address(frens), address(0xbad)), 0, "a new swapper gets nothing up front");
    }

    /* ── the floor ──────────────────────────────────────────────── */

    /// @dev n mints: the first buys its floor share at once (one buy a block), the rest are bought in the next block
    function _floorOf(uint256 n) internal {
        for (uint256 i; i < n; ++i) _mintOne(i % 2 == 0 ? alice : bob);
        vm.roll(vm.getBlockNumber() + 1);
        if (frens.floorImd() != 0) frens.buyFloor(1);
    }

    /// @dev The floor in $IMD terms: what waits, and the reserve at the mock's rate
    function _floorValue() internal view returns (uint256) {
        return frens.floorImd() + frens.reserve() / swapper.rate();
    }

    function test_FloorIsReserveOverFrensOut() public {
        _floorOf(4);
        assertEq(frens.reserve(), 4 * 0.19e18 * 70_000);
        (uint256 f, uint256 fi) = frens.floorPerFren();
        assertEq(f, 0.19e18 * 70_000);
        assertEq(fi, 0, "all of it bought into the reserve");
    }

    function test_RecyclePaysTheFloorAndKeepsIt() public {
        _floorOf(4);
        (uint256 f,) = frens.floorPerFren();
        vm.prank(alice);
        frens.recycle(1);
        assertEq(imd6900.balanceOf(alice), f);
        assertEq(frens.ownerOf(1), address(frens));
        (uint256 after_,) = frens.floorPerFren();
        assertEq(after_, f, "recycling leaves the floor where it was");
    }

    function test_BuyingFromTheTreasuryRaisesTheFloor() public {
        _floorOf(4);
        vm.prank(alice);
        frens.recycle(1);
        (uint256 f,) = frens.floorPerFren();
        imd6900.mint(bob, 1e30);
        vm.startPrank(bob);
        imd6900.approve(address(frens), type(uint256).max);
        frens.buyTreasury(1, 2 * f, 0);
        vm.stopPrank();
        assertEq(frens.ownerOf(1), bob);
        (uint256 after_,) = frens.floorPerFren();
        assertGt(after_, f);
    }

    function test_BuyTreasuryRespectsMaxPay() public {
        _floorOf(2);
        vm.prank(alice);
        frens.recycle(1);
        imd6900.mint(bob, 1e30);
        vm.startPrank(bob);
        imd6900.approve(address(frens), type(uint256).max);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        frens.buyTreasury(1, 1, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The floor is both parts: $IMD still waiting to be bought in counts, and recycling pays its share of it
    function test_RecyclePaysTheWaitingImdToo() public {
        swapper.setSpend(0); // the pool at its price limit: nothing bought yet, 4 x 0.19 waiting
        for (uint256 i; i < 4; ++i) _mintOne(i % 2 == 0 ? alice : bob);
        (uint256 f, uint256 fi) = frens.floorPerFren();
        assertEq(f, 0);
        assertEq(fi, 0.19e18);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        (uint256 paid, uint256 imdPaid) = frens.recycle(1);
        assertEq(paid, 0);
        assertEq(imdPaid, 0.19e18);
        assertEq(imd.balanceOf(alice) - before, 0.19e18);
        (, uint256 fi2) = frens.floorPerFren();
        assertEq(fi2, fi, "the others' floor is untouched");
    }

    /// @dev Buying back costs twice both parts, so no round trip through the treasury takes anything out of the floor
    function test_TreasuryRoundTripCostsTheFloor() public {
        swapper.setSpend(5_000); // each buy stops halfway: part bought in, part waiting
        for (uint256 i; i < 4; ++i) _mintOne(i % 2 == 0 ? alice : bob);
        vm.prank(alice);
        frens.recycle(1);
        (uint256 f, uint256 fi) = frens.floorPerFren();
        assertGt(f, 0);
        assertGt(fi, 0);
        imd6900.mint(bob, 1e30);
        uint256 reserve0 = frens.reserve();
        uint256 waiting0 = frens.floorImd();
        vm.startPrank(bob);
        imd6900.approve(address(frens), type(uint256).max);
        imd.approve(address(frens), type(uint256).max);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        frens.buyTreasury(1, 2 * f, 2 * fi - 1);
        (uint256 paid, uint256 imdPaid) = frens.buyTreasury(1, 2 * f, 2 * fi);
        frens.recycle(1);
        vm.stopPrank();
        assertEq(paid, 2 * f);
        assertEq(imdPaid, 2 * fi);
        assertGe(frens.reserve(), reserve0);
        assertGe(frens.floorImd(), waiting0);
    }

    /// @dev A fren that reaches the treasury without recycle (a plain transfer to the contract) counts as in it: out of
    ///      the floor's share count, and for sale like the rest. Before, the counter missed it: `out` stayed one too
    ///      high and buying it back took another fren's place in the counter, so that one could never be bought.
    function test_FrenSentStraightToTheTreasuryCounts() public {
        _floorOf(3);
        vm.prank(alice);
        frens.transferFrom(alice, address(frens), 1);
        assertEq(frens.inTreasury(), 1, "a fren sent here is in the treasury");
        vm.prank(bob);
        frens.recycle(2);
        assertEq(frens.inTreasury(), 2);
        (uint256 f,) = frens.floorPerFren();
        assertEq(f, frens.reserve() / 1, "the one fren still out holds the whole floor");
        imd6900.mint(bob, 1e30);
        vm.startPrank(bob);
        imd6900.approve(address(frens), type(uint256).max);
        frens.buyTreasury(1, type(uint256).max, type(uint256).max);
        frens.buyTreasury(2, type(uint256).max, type(uint256).max); // the counter can't run out
        vm.stopPrank();
        assertEq(frens.inTreasury(), 0);
    }

    /// @dev Nobody mints into the treasury: its frens would carry the tier of the contract's own bag (the floor's $IMD
    ///      and IMD6900), and anyone could buy them out of it, a rare tier without holding anything.
    function test_NoMintIntoTheTreasury() public {
        _floorOf(2);
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        frens.requestMintFor(address(frens), 1, type(uint256).max);
    }

    function test_OnlyHoldersRecycle() public {
        _floorOf(2);
        vm.prank(bob);
        vm.expectRevert(IMD6900Frens.NotHolder.selector);
        frens.recycle(1);
    }

    /// @dev A buy takes at most maxImdPerBuy (50 $IMD); the rest waits for the next block's
    function test_FloorBuysAreCapped() public {
        for (uint256 i; i < 300; ++i) _request(alice); // the first buys its 0.19; 299 x 0.19 wait
        vm.roll(vm.getBlockNumber() + 1);
        frens.buyFloor(1);
        assertEq(frens.floorImd(), 299 * 0.19e18 - 50e18);
    }

    function test_FeeEthBuysTheFloor() public {
        _floorOf(2);
        uint256 r = frens.reserve();
        (bool ok,) = address(frens).call{value: 0.1 ether}("");
        assertTrue(ok);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeper);
        frens.buyFloorWithEth(0.1 ether, 1);
        assertGt(frens.reserve(), r);
    }

    function test_RoyaltiesPayTheFloor() public {
        assertTrue(frens.supportsInterface(0x2a55205a), "ERC-2981");
        (address to, uint256 amount) = frens.royaltyInfo(1, 1 ether);
        assertEq(to, address(frens), "royalties come here");
        assertEq(amount, 0.05 ether, "5% by default");
        _floorOf(2);
        uint256 r = frens.reserve();
        (bool ok,) = address(frens).call{value: amount}("");
        assertTrue(ok);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeper);
        frens.buyFloorWithEth(amount, 1);
        assertGt(frens.reserve(), r, "the royalty raised the floor");
    }

    function test_RoyaltyBpsIsCappedAndOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        frens.setParams(1_000, 1, 50e18, 0.25 ether);
        vm.prank(timelock);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        frens.setParams(1_001, 1, 50e18, 0.25 ether);
        vm.prank(timelock);
        frens.setParams(1_000, 1, 50e18, 0.25 ether);
        (, uint256 amount) = frens.royaltyInfo(1, 1 ether);
        assertEq(amount, 0.1 ether);
    }

    /// @dev Mints buy as they come; anyone buys what's left, one buy a block (the swapper's price limit is what makes
    ///      a buy safe to leave open)
    function test_FloorBuysAreAnyones_onePerBlock() public {
        _mintOne(alice);
        assertEq(frens.floorImd(), 0, "the mint bought its share");
        assertEq(frens.reserve(), 0.19e18 * 70_000);
        _mintOne(bob); // same block: waits
        assertEq(frens.floorImd(), 0.19e18);
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        frens.buyFloor(1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        frens.buyFloor(1);
        assertEq(frens.floorImd(), 0);
        (bool ok,) = address(frens).call{value: 0.3 ether}("");
        assertTrue(ok);
        vm.prank(alice);
        frens.buyFloorWithEth(0.1 ether, 1); // the fee ETH keeps its own pace: same block as that $IMD buy
        vm.prank(bob);
        vm.expectRevert(IMD6900Frens.TooSoon.selector);
        frens.buyFloorWithEth(0.1 ether, 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        frens.buyFloorWithEth(0.1 ether, 1);
    }

    /// @dev A dust ETH buy at the top of every block can't keep the mints' $IMD out of the reserve
    function test_DustEthBuyCannotTakeTheMintsTurn() public {
        (bool ok,) = address(frens).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(bob);
        frens.buyFloorWithEth(1e9, 0);
        _request(alice);
        assertEq(frens.floorImd(), 0, "the mint still bought its share this block");
    }

    /// @dev Too little gas for the floor buy reverts the mint rather than skipping the buy: a wallet's estimate always
    ///      leaves room for it
    function test_MintNeverSkipsTheBuyForWantOfGas() public {
        vm.prank(alice);
        (bool ok,) = address(frens).call{gas: 350_000}(abi.encodeCall(IMD6900Frens.requestMint, (1, type(uint256).max)));
        assertFalse(ok, "not enough gas for the buy: no mint");
        vm.prank(alice);
        frens.requestMint(1, type(uint256).max);
        assertEq(frens.floorImd(), 0, "bought");
    }

    /// @dev A mint whose swap fails still goes through; its share waits
    function test_AMintNeverFailsOnTheSwap() public {
        address broken = address(new RevertingSwapper());
        vm.prank(timelock);
        frens.setModules(broken, address(0));
        _mintOne(alice);
        assertEq(frens.floorImd(), 0.19e18);
        assertEq(frens.reserve(), 0);
    }

    function test_ShortSwapReverts() public {
        swapper.setSpend(0);
        _mintOne(alice);
        swapper.setSpend(10_000);
        swapper.setRate(1);
        uint256 have = frens.floorImd();
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(IMD6900Frens.SwapShort.selector);
        frens.buyFloor(have * 2);
    }

    function test_ReserveOnlyLeavesThroughRecycle() public {
        _floorOf(4);
        uint256 r = frens.reserve();
        vm.startPrank(timelock);
        frens.setModules(address(0xdead), address(0));
        frens.setRoles(address(0xdead), address(0xdead), address(0xdead), address(0xdead));
        vm.stopPrank();
        assertEq(imd6900.balanceOf(address(frens)), r);
    }

    /* ── ERC-721C ────────────────────────────────────────────────── */

    function test_IsACreatorToken() public view {
        assertEq(frens.getTransferValidator(), frens.DEFAULT_TRANSFER_VALIDATOR(), "Limit Break's default until the owner picks");
        (bytes4 sel, bool isView) = frens.getTransferValidationFunction();
        assertEq(sel, bytes4(keccak256("validateTransfer(address,address,address,uint256)")));
        assertTrue(isView);
        assertTrue(frens.supportsInterface(type(ICreatorToken).interfaceId), "ICreatorToken");
        assertTrue(frens.supportsInterface(type(ICreatorTokenLegacy).interfaceId), "the legacy one too");
        assertTrue(frens.supportsInterface(0x80ac58cd), "ERC-721");
    }

    function test_TradesGoPastTheValidator() public {
        MockValidator v = new MockValidator();
        vm.prank(timelock);
        frens.setTransferValidator(address(v));
        uint256 id = _mintOne(alice);
        assertEq(v.tokenType(), 721, "it told the validator it is an ERC-721");
        vm.prank(alice);
        frens.transferFrom(alice, bob, id);
        address market = makeAddr("market");
        vm.prank(bob);
        frens.setApprovalForAll(market, true);
        vm.prank(market);
        vm.expectRevert(MockValidator.Blocked.selector);
        frens.transferFrom(bob, alice, id);
        v.allow(market);
        vm.prank(market);
        frens.transferFrom(bob, alice, id);
        assertEq(frens.ownerOf(id), alice);
    }

    function test_FloorMovesSkipTheValidator() public {
        MockValidator v = new MockValidator();
        vm.prank(timelock);
        frens.setTransferValidator(address(v));
        _floorOf(2);
        vm.prank(alice);
        frens.recycle(1);
        imd6900.mint(bob, 1e30);
        vm.startPrank(bob);
        imd6900.approve(address(frens), type(uint256).max);
        frens.buyTreasury(1, type(uint256).max, type(uint256).max);
        vm.stopPrank();
        assertEq(frens.ownerOf(1), bob);
    }

    function test_OnlyTheOwnerSetsTheValidator() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        frens.setTransferValidator(address(0));
        vm.prank(timelock);
        vm.expectRevert(IMD6900Frens.InvalidTransferValidator.selector);
        frens.setTransferValidator(makeAddr("not a contract"));
        vm.prank(timelock);
        frens.setTransferValidator(address(0));
        assertEq(frens.getTransferValidator(), address(0));
        uint256 id = _mintOne(alice);
        address anyone = makeAddr("anyone");
        vm.prank(alice);
        frens.setApprovalForAll(anyone, true);
        vm.prank(anyone);
        frens.transferFrom(alice, bob, id);
    }

    /* ── batches: one job, up to 69 frens ───────────────────────── */

    function _commons(uint256 n) internal returns (uint24[] memory a) {
        a = new uint24[](n);
        for (uint256 i; i < n; ++i) a[i] = _common();
    }

    function _revealMany(uint256 id, uint24[] memory combos) internal {
        uint256 d = block.timestamp + 1 hours;
        frens.reveal(id, combos, "job-1", keccak256("out"), d, _signMany(frens, relayerKey, id, combos, d), combos.length);
    }

    function _revealManyReverts(uint256 id, uint24[] memory combos, bytes memory err) internal {
        uint256 d = block.timestamp + 1 hours;
        bytes memory sig = _signMany(frens, relayerKey, id, combos, d);
        vm.expectRevert(err);
        frens.reveal(id, combos, "job-1", keccak256("out"), d, sig, combos.length);
    }

    /// @dev Ten frens: minted at once, 6.90 paid, one job's 0.50, the other 6.40 to the floor
    function test_BatchPaysOneJob() public {
        vm.prank(alice);
        uint256 id = frens.requestMint(10, type(uint256).max);
        assertEq(frens.balanceOf(alice), 10);
        assertEq(imd.balanceOf(address(frens)), 0.5e18, "the job's part waits here");
        assertEq(frens.jobBudget(), 0.5e18);
        assertEq(_floorValue(), 6.4e18, "the rest went to the floor");
        assertEq(frens.floorImd(), 0, "bought into IMD6900 at once");
        (,,,, uint8 count,,,,,) = frens.requests(id);
        assertEq(count, 10);
    }

    function test_BatchCountIsOneTo69() public {
        vm.startPrank(alice);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        frens.requestMint(0, type(uint256).max);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        frens.requestMint(70, type(uint256).max);
        frens.requestMint(69, type(uint256).max);
        vm.stopPrank();
    }

    function test_BatchRevealsThemAll() public {
        vm.prank(alice);
        uint256 id = frens.requestMint(10, type(uint256).max);
        _approve(id);
        uint24[] memory c = _commons(10);
        _revealMany(id, c);
        for (uint256 i; i < 10; ++i) {
            assertEq(frens.ownerOf(i + 1), alice);
            assertEq(frens.comboOf(i + 1), c[i]);
            assertTrue(frens.taken(c[i]));
        }
        assertTrue(frens.seedOf(1) != frens.seedOf(2), "each its own seed");
    }

    /// @dev The voucher names exactly the request's frens: no fewer, no more, not another order
    function test_BatchRevealIsExactlyTheVoucher() public {
        vm.prank(alice);
        uint256 id = frens.requestMint(3, type(uint256).max);
        uint24[] memory c = _commons(4);
        _revealManyReverts(id, c, abi.encodeWithSelector(IMD6900Frens.BadRequest.selector)); // four for three
        uint24[] memory three = new uint24[](3);
        (three[0], three[1], three[2]) = (c[0], c[1], c[2]);
        uint256 d = block.timestamp + 1 hours;
        bytes memory sig = _signMany(frens, relayerKey, id, three, d);
        (three[0], three[1]) = (c[1], c[0]);
        vm.expectRevert(IMD6900Frens.BadVoucher.selector);
        frens.reveal(id, three, "job-1", keccak256("out"), d, sig, three.length); // reordered
        (three[0], three[1]) = (c[0], c[1]);
        frens.reveal(id, three, "job-1", keccak256("out"), d, sig, three.length);
        assertEq(frens.comboOf(3), c[2]);
    }

    function test_BatchCannotRepeatAFren() public {
        vm.prank(alice);
        uint256 id = frens.requestMint(2, type(uint256).max);
        uint24[] memory c = _commons(2);
        c[1] = c[0];
        _revealManyReverts(id, c, abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(2)));
    }

    /// @dev Each fren counts against the caps before the next is checked
    function test_BatchCountsTheCapsAsItGoes() public {
        frens = _deploy([uint16(2218), 2, 2]);
        vm.prank(alice);
        imd.approve(address(frens), type(uint256).max);
        vm.prank(alice);
        uint256 id = frens.requestMint(3, type(uint256).max);
        uint24[] memory c = new uint24[](3);
        for (uint8 i; i < 3; ++i) c[i] = _combo(MUMU, i, 0, 0, 0, 0, 0, 0);
        _revealManyReverts(id, c, abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(3)));
        c[2] = _combo(BOBO, 0, 0, 0, 0, 0, 0, 0);
        _revealMany(id, c);
        assertEq(frens.ruleOf(0, MUMU).minted, 2);
    }

    function test_BatchSoldOut() public {
        vm.startPrank(alice);
        for (uint256 i; i < 222; ++i) frens.requestMint(10, type(uint256).max); // 2220 minted
        vm.expectRevert(IMD6900Frens.SoldOut.selector);
        frens.requestMint(3, type(uint256).max);
        frens.requestMint(2, type(uint256).max);
        vm.stopPrank();
        assertEq(frens.totalMinted(), 2222);
    }

    /// @dev A low-tier batch holds that many pepes back until it reveals, and a higher tier can't take them
    function test_BatchHoldsPepesForLowTiers() public {
        frens = _deploy([uint16(4), 1109, 1109]);
        address low = _holder("lowbatch", 0, 690_000e18, 0); // tier 1 by IMD6900: below mumu, up to 6 a request
        imd.mint(low, 10e18);
        vm.prank(low);
        imd.approve(address(frens), type(uint256).max);
        vm.prank(low);
        frens.requestMint(3, type(uint256).max); // holds 3 of the 4 pepes
        vm.prank(low);
        vm.expectRevert(IMD6900Frens.SoldOut.selector);
        frens.requestMint(2, type(uint256).max);
        assertEq(frens.openLowTier(), 3);
        vm.startPrank(alice);
        imd.approve(address(frens), type(uint256).max);
        uint256 id = frens.requestMint(2, type(uint256).max);
        vm.stopPrank();
        uint24[] memory c = new uint24[](2);
        (c[0], c[1]) = (_combo(PEPE, 0, 0, 0, 0, 0, 0, 0), _combo(PEPE, 1, 0, 0, 0, 0, 0, 0));
        _revealManyReverts(id, c, abi.encodeWithSelector(IMD6900Frens.BadCombo.selector, uint8(3))); // the 2nd is held
        c[1] = _combo(MUMU, 1, 0, 0, 0, 0, 0, 0);
        _revealMany(id, c);
    }

    /* ── how many a request may ask for: the bag decides, up to 69 ─ */

    function _asks(address who, uint8 n) internal {
        vm.prank(who);
        frens.requestMint(n, type(uint256).max);
    }

    function test_MaxMintGrowsWithTheBag() public {
        address t0 = _holder("t0", 0, 0, 0);
        imd.mint(t0, 5e18);
        address t1 = _holder("t1", 0, 690_000e18, 0);
        imd.mint(t1, 10e18);
        address t2 = _holder("t2", 0, 6_900_000e18, 0);
        imd.mint(t2, 20e18);
        address t3 = _holder("t3", 0, 0, 1);
        imd.mint(t3, 60e18);
        uint8[4] memory max = [1, 6, 22, 69];
        address[4] memory who = [t0, t1, t2, t3];
        for (uint256 t; t < 4; ++t) {
            assertEq(frens.tierOf(who[t]), t);
            if (t < 3) {
                vm.prank(who[t]);
                vm.expectRevert(abi.encodeWithSelector(IMD6900Frens.OverTierLimit.selector, max[t]));
                frens.requestMint(max[t] + 1, type(uint256).max);
            }
            _asks(who[t], max[t]);
        }
    }

    /// @dev What the site shows (FrenMinter.maxRequest): the most one request can ask for. Paying in $IMD takes the
    ///      price out of the bag first; paying in ETH leaves the bag as it is.
    function test_MaxRequest() public {
        FrenMinter m = new FrenMinter(address(0), address(frens), address(0), address(0));
        assertEq(m.maxRequest(makeAddr("empty"), false), 0);
        assertEq(m.maxRequest(makeAddr("empty"), true), 1, "with ETH anyone can mint one");
        address small = makeAddr("small");
        imd.mint(small, 1e18);
        assertEq(m.maxRequest(small, false), 1, "tier 0: one");
        address hundred = makeAddr("hundred");
        imd.mint(hundred, 100e18); // 22 keeps 84.82: tier 2; 23 would be over tier 2's limit
        assertEq(m.maxRequest(hundred, false), 22);
        assertEq(m.maxRequest(hundred, true), 22, "100 $IMD is tier 2 either way");
        address seventy = makeAddr("seventy");
        imd.mint(seventy, 70e18);
        assertEq(m.maxRequest(seventy, false), 6, "paying drops it to tier 1");
        assertEq(m.maxRequest(seventy, true), 22, "with ETH it stays tier 2");
        address nft = makeAddr("nft holder");
        idmd.mint(nft, 1);
        imd.mint(nft, 50e18);
        assertEq(m.maxRequest(nft, false), 69, "an identity.md is tier 3 whatever is paid");
        address poorNft = makeAddr("nft, little $IMD");
        idmd.mint(poorNft, 1);
        imd.mint(poorNft, 7e18);
        assertEq(m.maxRequest(poorNft, false), 10, "as many as it can pay for");
        assertEq(m.maxRequest(poorNft, true), 69);
        vm.prank(hundred);
        imd.approve(address(frens), type(uint256).max);
        _asks(hundred, 22);
    }

    /* ── the price curve ────────────────────────────────────────── */

    function _curved() internal returns (IMD6900Frens f) {
        bytes[] memory b = new bytes[](1);
        b[0] = vm.readFileBinary("script/frens/price/prices.bin");
        f = new IMD6900Frens(timelock, address(imd), address(imd6900), address(idmd), address(permit2), proxy, payTo, keeper, relayer, new FrenArt().write(b)[0]);
        vm.startPrank(timelock);
        _rules(f, [uint16(1598), 312, 312]);
        f.sealTraits();
        f.setMintOpen(true);
        vm.stopPrank();
        vm.prank(alice);
        imd.approve(address(f), type(uint256).max);
    }

    /// @dev The table is the S-curve 6.9 / (1 + 9 e^(-k n)): it starts at 0.69, never goes down, and is a logistic with a
    ///      6.9 ceiling: 6.9 / p(n) - 1 shrinks by the same factor e^(-k) every fren (0.99811 for k = 0.0018884), to
    ///      the table's 0.0001. All 2222 cost 7,380 $IMD (~30 ETH when it was set).
    function test_PriceTableIsTheCurve() public {
        IMD6900Frens f = _curved();
        uint256 last;
        uint256 total;
        uint256 rPrev;
        for (uint256 n; n < 2222; ++n) {
            uint256 p = f.priceOf(n);
            assertGe(p, last, "never goes down");
            assertLt(p, 6.9e18, "under the ceiling");
            last = p;
            total += p;
            uint256 r = 6.9e18 * 1e18 / p - 1e18; // 9 e^(-k n), in 1e18
            if (n > 0) assertApproxEqRel(r * 1e18 / rPrev, 0.998113389e18, 0.00025e18, "a logistic: the same step every fren");
            rPrev = r;
        }
        assertEq(f.priceOf(0), 0.69e18);
        assertEq(f.priceOf(2221), 6.0752e18);
        assertEq(f.priceOf(1162), 3.445e18);
        assertApproxEqAbs(total, 7380e18, 0.01e18, "all 2222: 7,380 $IMD");
        assertEq(f.quote(2222), total);
    }

    /// @dev The price follows the frens sold: each request pays the next ones on the curve
    function test_PriceRisesWithMints() public {
        IMD6900Frens f = _curved();
        assertEq(f.quote(1), 0.69e18);
        uint256 ten = f.quote(10);
        uint256 sum;
        for (uint256 n; n < 10; ++n) sum += f.priceOf(n);
        assertEq(ten, sum);
        vm.prank(alice);
        f.requestMint(10, ten);
        assertEq(f.floorImd(), ten - 0.5e18, "all but the job goes to the floor");
        assertEq(f.quote(1), f.priceOf(10));
        vm.startPrank(alice);
        for (uint256 i; i < 15; ++i) f.requestMint(69, type(uint256).max); // 1045 frens in
        vm.stopPrank();
        assertEq(f.quote(1), f.priceOf(1045));
        assertApproxEqAbs(f.quote(1), 3.0655e18, 0.0001e18, "fren 1046 costs ~3.07");
    }

    function test_MaxPayStopsAPriceThatMoved() public {
        IMD6900Frens f = _curved();
        uint256 q = f.quote(5);
        vm.prank(bob);
        imd.approve(address(f), type(uint256).max);
        vm.prank(bob);
        f.requestMint(5, type(uint256).max); // someone mints first
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        f.requestMint(5, q);
    }

    /// @dev Someone else pays (FrenMinter, for ETH): the frens, the request and the tier are the minter's
    function test_RequestMintFor() public {
        address carol = _holder("carol", 69e18, 0, 0); // tier 2 by her own bag
        uint256 aliceBefore = imd.balanceOf(alice);
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(alice);
        uint256 id = frens.requestMintFor(carol, 22, type(uint256).max);
        (address minter, uint8 tier,,, uint8 count,,,,,) = frens.requests(id);
        assertEq(minter, carol);
        assertEq(tier, 2);
        assertEq(count, 22);
        assertEq(aliceBefore - imd.balanceOf(alice), 22 * 0.69e18, "the payer pays");
        assertEq(imd.balanceOf(carol), carolBefore, "the minter's bag is untouched");
    }

    function test_SetMaxMint() public {
        vm.startPrank(timelock);
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        frens.setMaxMint([uint8(0), 6, 22, 69]);
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        frens.setMaxMint([uint8(1), 6, 22, 70]);
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        frens.setMaxMint([uint8(1), 9, 6, 69]);
        frens.setMaxMint([uint8(2), 9, 30, 69]);
        vm.stopPrank();
        assertEq(frens.maxMint(1), 9);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        frens.setMaxMint([uint8(1), 6, 22, 69]);
    }

    /* ── revealing a big request in parts ───────────────────────── */

    function _revealPart(uint256 id, uint24[] memory combos, uint256 upTo) internal {
        uint256 d = block.timestamp + 1 hours;
        frens.reveal(id, combos, "job-1", keccak256("out"), d, _signMany(frens, relayerKey, id, combos, d), upTo);
    }

    function revealPart(uint256 id, uint24[] memory combos, uint256 upTo) external {
        _revealPart(id, combos, upTo);
    }

    /// @dev 69 frens minted at once, revealed in three parts, each well under a transaction's gas cap
    function test_RevealInParts() public {
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 id = frens.requestMint(69, type(uint256).max);
        emit log_named_uint("gas, minting 69", g - gasleft());
        assertEq(frens.balanceOf(alice), 69);
        _approve(id);
        uint24[] memory c = _commons(69);
        g = gasleft();
        _revealPart(id, c, 30);
        emit log_named_uint("gas, revealing 30", g - gasleft());
        assertLt(g - gasleft(), 8_000_000);
        (,,,,, uint8 revealed,,,,) = frens.requests(id);
        assertEq(revealed, 30);
        assertEq(frens.seedOf(31), 0, "the rest not yet");
        _revealPart(id, c, 60);
        _revealPart(id, c, 69);
        assertEq(frens.comboOf(69), c[68]);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        this.revealPart(id, c, 69);
    }

    /// @dev A later part may come with a newer voucher (a fren got taken meanwhile), never one that changes what's revealed
    function test_LaterPartsAgreeOnWhatIsRevealed() public {
        vm.prank(alice);
        uint256 id = frens.requestMint(5, type(uint256).max);
        uint24[] memory c = _commons(5);
        _revealPart(id, c, 2);
        uint24[] memory changed = new uint24[](5);
        for (uint256 i; i < 5; ++i) changed[i] = c[i];
        changed[1] = _common();
        vm.expectRevert(IMD6900Frens.BadVoucher.selector);
        this.revealPart(id, changed, 5);
        c[4] = _common(); // the relayer swapped a fren not revealed yet
        _revealPart(id, c, 5);
        assertEq(frens.comboOf(5), c[4]);
    }

    function test_PartsOnlyGoForward() public {
        vm.prank(alice);
        uint256 id = frens.requestMint(5, type(uint256).max);
        uint24[] memory c = _commons(5);
        _revealPart(id, c, 3);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        this.revealPart(id, c, 3);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        this.revealPart(id, c, 6);
    }
}
