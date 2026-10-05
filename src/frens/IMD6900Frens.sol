// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

interface IPermit2Min {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonceBitmap(address owner, uint256 wordPos) external view returns (uint256);
}

/// @notice Turns the floor's $IMD (and the fee ETH) into IMD6900. The owner picks the module; it never holds funds.
interface IFrenSwapper {
    function imdToImd6900(uint256 imdIn, uint256 minOut, address to) external returns (uint256 out);
    function ethToImd6900(uint256 minOut, address to) external payable returns (uint256 out);
    function floorRate() external view returns (uint256); // IMD6900 per $IMD at its dearest (1e18)
}

/// @notice The workers' window: the frens right after the opening go only to identity.md holders, one per NFT
interface IWorkerGate {
    function spend(address minter, uint256 count) external; // reverts unless `minter` may mint `count` now
}

interface IExttloadMin {
    function exttload(bytes32 slot) external view returns (bytes32);
}

interface IWethMin {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256) external;
}

/// @notice ERC-721C (Limit Break creator tokens): marketplaces read these to know transfers are validated
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);
    function getTransferValidator() external view returns (address validator);
    function setTransferValidator(address validator) external;
    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);
}

interface ICreatorTokenLegacy {
    event TransferValidatorUpdated(address oldValidator, address newValidator);
    function getTransferValidator() external view returns (address validator);
    function setTransferValidator(address validator) external;
}

interface ITransferValidator721 {
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
    function setTokenTypeOfCollection(address collection, uint16 tokenType) external;
}

interface IFrenRenderer {
    function tokenURI(uint256 tokenId, uint24 combo, uint256 seed) external view returns (string memory);
    function pendingURI(uint256 tokenId) external view returns (string memory);
}

/// @title IMD6900Frens - 2222 frens, each built by five agents in the IMD swarm, each backed by a floor of IMD6900
/// @notice The price: frens 1-560 (the strategy's first and the workers' window) rise slowly from 0.69 to 0.95 $IMD;
///  then the price grows exponentially, turns near fren 640 and plateaus at 3.24; all 2222 cost 5,422 $IMD (priceOf;
///  the table is written at deploy, see script/frens/price). A mint never costs less than the floor it joins (quote). One request mints 1 to 69 frens at once, as many as the minter's bag allows; they're
///  unrevealed until a job in the IMD swarm builds them. It pays:
///  - 0.50 for that job, in which five agents build the request's frens layer by layer: background, character and
///    face, eye lens, coat and shirt, hat and item. Each sees what the ones before it chose.
///  - all the rest to the floor: the mint buys it into IMD6900 on the IMD6900/$IMD pool right away (one buy a block;
///    each stops before the price moves half the pool's fee, so no sandwich pays; the rest waits for the next buy).
///    Pay in ETH through FrenMinter: it buys the $IMD on IMD's ETH/$IMD pool first, so ETH -> $IMD -> IMD6900.
///  A big request reveals in parts (each a transaction under EIP-7825's gas cap), all from the one voucher.
///
///  What a minter holds decides how rare a fren the agents may build. requestMint reads their $IMD, IMD6900 and
///  identity.md NFTs (never while v4's PoolManager is unlocked: no borrowed bag) and gives the request a tier (0 to 3);
///  every trait value has a cap and a lowest tier that may take it.
///
///  When the job is done, the relayer reads the agents' frens from IMD and signs a voucher for them; anyone sends it
///  and the frens reveal. The contract checks everything that matters itself (each combo is unique, under its caps,
///  allowed for the request's tier); the voucher's job id and output hash go on chain so anyone can compare them with
///  IMD's public job record. A job that doesn't land reveals nothing, and nothing is refunded: the frens stay minted,
///  unrevealed and backed by the floor, until someone pays another job for them (retryJob).
///
///  The floor is MiFrens' flywheel:
///  - floorPerFren = reserve / frens out in the world.
///  - recycle(): any holder can sell a fren to the treasury for the floor, any time: its share of the IMD6900 reserve
///    and of the $IMD still waiting to be bought into it.
///  - buyTreasury(): costs twice the floor (both parts), and all of it stays in the floor, so it rises for everyone.
///  - Trading-fee ETH and marketplace royalties are bought into the reserve too, through $IMD (see FrenSwapper).
///  - Nothing else takes IMD6900 out of the reserve: there is no withdraw.
///
///  The frens are ERC-721C: every trade between holders is checked by Limit Break's transfer validator, so they
///  trade only where the creator royalty is paid (OpenSea, Magic Eden), and that royalty buys the floor like every
///  other fee. Mints, burns and the floor's own moves (recycle, buyTreasury) are never checked.
///
/// @dev Roles:
///  - Governor (the Ethereum timelock after the handover): every setting that touches the mint, the floor or the
///    money (modules, roles, tiers, caps, opening the mint), and the trait rules until they are sealed.
///  - Owner (a team wallet, never the timelock): the collection on marketplaces. OpenSea and the others treat owner()
///    as the collection's owner, who signs in to edit its page, so it must be a wallet that can sign. On chain it only
///    sets the royalty (at most 10%, always paid to this contract's floor), the transfer validator and the art (the
///    renderer, until freezeArt).
///  - Keeper: approves a request's single job payment (the contract "signs" it through ERC-1271: exactly JOB_PRICE of
///    $IMD to `imdPayTo` through the x402 Permit2 proxy).
///  - Relayer: signs claim vouchers. It cannot mint anything the contract's own checks refuse.
///  A combo (24 bits) packs one value per trait: character 0-1 | face 2-5 | eye 6-7 | coat 8-9 | shirt 10-12 |
///  hat 13-14 | background 15-18 | item 19-22.
contract IMD6900Frens is ERC721, Ownable, ReentrancyGuard {
    /* ── constants ──────────────────────────────────────────────── */

    uint256 public constant SUPPLY = 2222;
    uint256 internal constant PRICE_UNIT = 1e14; // the price table's unit: 0.0001 $IMD
    uint256 public constant JOB_PRICE = 0.5e18; // what IMD charges for one paid job
    uint256 internal constant MAX_PER_REQUEST = 69; // frens one job builds, at most
    uint256 internal constant FLOOR_BUY_GAS = 400_000; // what a floor swap may use (it takes ~150k)
    /// @notice Wrapped ETH on mainnet: what marketplaces pay royalties in when a sale settles in WETH
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    /// @notice Uniswap v4's PoolManager holds most of the $IMD there is, and lends any of it for free inside unlock():
    ///         a bag is read only when it's locked, so a borrowed one can't reach a tier
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23; // Lock.IS_UNLOCKED_SLOT

    /// @notice The traits, in combo order, and how many values each has
    uint8 internal constant CHARACTER = 0;
    uint8 internal constant FACE = 1;
    uint8 internal constant EYE = 2;
    uint8 internal constant COAT = 3;
    uint8 internal constant SHIRT = 4;
    uint8 internal constant HAT = 5;
    uint8 internal constant BACKGROUND = 6;
    uint8 internal constant ITEM = 7;
    uint8 internal constant TRAITS = 8;
    uint8 internal constant TIERS = 3; // 1..3 above the open tier 0
    uint8 internal constant MAX_PAIR_RULES = 16;

    address public immutable imd; // $IMD
    address public immutable imd6900; // IMD6900
    address public immutable identity; // identity.md
    address public immutable permit2; // Uniswap Permit2
    address public immutable x402Proxy; // the x402 "exact" Permit2 proxy IMD's payments go through
    address internal immutable priceTable; // SSTORE2: the n-th fren's price, 3 bytes each in PRICE_UNITs, fren 0 first

    /* ── settings (owner) ───────────────────────────────────────── */

    address public keeper;
    address public relayer;
    address public imdPayTo; // IMD's payee for paid jobs
    address public swapper;
    address public renderer;
    address public workerGate; // while it says so, a mint needs a worker credit (FrenWorkerGate)
    address public governor; // the mint's and the floor's settings: the timelock after the handover
    bool public artFrozen; // once set, the renderer never changes
    uint256 public maxImdPerBuy = 50e18; // floor buys, per call
    uint256 public maxEthPerBuy = 0.25 ether;
    bool public mintOpen;

    /// @notice A tier's thresholds, lowest tier first: holding at least this much of one asset reaches that tier
    uint256[TIERS] public imdTier = [uint256(6.9e18), 69e18, 690e18];
    uint256[TIERS] public imd6900Tier = [uint256(690_000e18), 6_900_000e18, 69_000_000e18];
    uint256[TIERS] public identityTier = [uint256(1), 1, 1]; // one identity.md is tier 3
    /// @notice The most frens one request may ask for, by the tier the bag left after paying reaches (0 to 3)
    uint8[TIERS + 1] public maxMint = [1, 6, 22, 69];

    /* ── the traits ─────────────────────────────────────────────── */

    struct Rule {
        uint16 cap; // most frens with this value
        uint16 minted;
        uint8 minTier; // lowest tier that may take it
    }

    /// @notice A pair of values that together need a higher tier (e.g. a gold coat on a mumu)
    struct PairRule {
        uint8 traitA;
        uint8 valueA;
        uint8 traitB;
        uint8 valueB;
        uint8 minTier;
    }

    mapping(uint256 => Rule) internal _rules; // trait << 8 | value
    PairRule[] internal _pairs;
    uint8 internal _configured; // a bit per trait whose rules are set
    bool public traitsSealed;
    mapping(uint24 => bool) public taken; // every fren is one of a kind

    /* ── requests ───────────────────────────────────────────────── */

    struct Request {
        address minter; // whom its frens were minted to
        uint8 tier; // the minter's at mint: what the agents may build
        bool lowTier; // below mumu and bobo: its frens hold pepes back until they're revealed
        bool jobApproved; // a job payment approved, spent or not
        uint8 count; // frens it minted
        uint8 revealed; // of those, revealed so far (a big request reveals in parts)
        uint8 jobs; // jobs paid for and not approved yet: the mint's own, then each retry
        uint32 firstToken; // its frens are firstToken .. firstToken + count - 1
        uint40 jobDeadline;
        uint256 jobNonce; // the Permit2 nonce of its job payment, to tell whether it was spent
    }

    mapping(uint256 => Request) public requests;
    uint256 public nextRequestId = 1;
    uint256 public openLowTier; // unrevealed frens below the tier mumu and bobo need: they can only be pepes
    uint256 public totalMinted;
    mapping(uint256 => uint24) public comboOf;
    mapping(uint256 => bytes32) internal revealedHashOf; // a request's frens revealed so far, chained: later parts agree
    mapping(uint256 => uint256) public seedOf; // 0 until revealed

    /* ── the floor ──────────────────────────────────────────────── */

    uint256 public reserve; // IMD6900 backing the frens out in the world
    uint256 public floorImd; // $IMD waiting to be bought into the reserve
    /// @notice Marketplace royalties (ERC-2981), paid to this contract and bought into the floor like every other fee
    uint96 public royaltyBps = 500;
    /// @notice A floor buy may run only this many blocks after the last: one buy per caller-chosen price, never a stream
    uint256 public buyDelayBlocks = 1;
    uint256 public lastFloorBuyBlock;
    uint256 public lastEthBuyBlock; // the fee ETH's buys keep their own pace: a dust one can't take the mints' turn
    uint256 public jobBudget; // $IMD for jobs not paid yet

    /* ── ERC-1271: the only payments this contract "signs" ────── */

    mapping(bytes32 => bool) internal approvedDigest; // isValidSignature answers for it

    /* ── ERC-721C: Limit Break's transfer validator ─────────────── */

    /// @notice The validator Limit Break's own ERC721C uses until the owner picks another
    address public constant DEFAULT_TRANSFER_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    uint16 internal constant TOKEN_TYPE_ERC721 = 721;
    bool internal _validatorSet; // once the owner sets one (address(0) turns validation off)
    address internal _transferValidator;

    /* ── events ─────────────────────────────────────────────────── */

    event FrensMinted(uint256 indexed requestId, address indexed minter, uint256 firstToken, uint8 count, uint8 tier, uint256 paid);
    event JobPaid(uint256 indexed requestId, address indexed payer);
    event JobApproved(uint256 indexed requestId, uint256 nonce, uint256 deadline, bytes32 permitDigest, bytes32 quoteDigest);
    event Revealed(uint256 indexed requestId, uint256 indexed tokenId, uint24 combo, string imdJobId, bytes32 outputHash);
    event TraitsSealed();
    event MinTierLowered(uint8 trait, uint8 value, uint8 minTier);
    event FloorBought(uint256 imdIn, uint256 ethIn, uint256 imd6900Out, uint256 reserve);
    event WethUnwrapped(uint256 amount);
    event Recycled(uint256 indexed tokenId, address indexed holder, uint256 paid, uint256 imdPaid);
    event TreasuryBought(uint256 indexed tokenId, address indexed buyer, uint256 paid, uint256 imdPaid);
    event Setting(bytes32 indexed what, uint256 value, address addr);

    error NotKeeper();
    error MintClosed();
    error TraitsNotSealed();
    error TraitsAreSealed();
    error BadTraits();
    error SoldOut();
    error BadRequest();
    error BadJob();
    error BadVoucher();
    error BadCombo(uint8 code);
    error Cap();
    error NotHolder();
    error NotInTreasury();
    error Invariant();
    error SwapShort();
    error TooSoon();
    error OverTierLimit(uint8 max);
    error Flash();
    error NothingToUnwrap();
    error InvalidTransferValidator();

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != governor) revert NotKeeper();
        _;
    }

    modifier onlyGovernor() {
        _onlyGovernor();
        _;
    }

    /// @dev The collection's marketplace settings: its owner, or the governor
    modifier onlyCurator() {
        _onlyCurator();
        _;
    }

    function _onlyGovernor() internal view {
        if (msg.sender != governor) revert Unauthorized();
    }

    function _onlyCurator() internal view {
        if (msg.sender != owner()) _onlyGovernor();
    }

    constructor(
        address owner_,
        address imd_,
        address imd6900_,
        address identity_,
        address permit2_,
        address x402Proxy_,
        address imdPayTo_,
        address keeper_,
        address relayer_,
        address priceTable_
    ) {
        if (priceTable_.code.length != 1 + 3 * SUPPLY) revert BadTraits();
        priceTable = priceTable_;
        _initializeOwner(owner_);
        governor = owner_; // the deployer, until the handover
        imd = imd_;
        imd6900 = imd6900_;
        identity = identity_;
        permit2 = permit2_;
        x402Proxy = x402Proxy_;
        imdPayTo = imdPayTo_;
        keeper = keeper_;
        relayer = relayer_;
        emit ICreatorToken.TransferValidatorUpdated(address(0), DEFAULT_TRANSFER_VALIDATOR);
        _registerTokenType(DEFAULT_TRANSFER_VALIDATOR);
    }

    function name() public pure override returns (string memory) {
        return "IMD6900 Frens";
    }

    function symbol() public pure override returns (string memory) {
        return "FREN6900";
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        if (!_exists(id)) revert TokenDoesNotExist();
        uint256 seed = seedOf[id];
        return seed == 0 ? IFrenRenderer(renderer).pendingURI(id) : IFrenRenderer(renderer).tokenURI(id, comboOf[id], seed);
    }

    /* ── the traits: set once, then sealed ──────────────────────── */

    /// @notice How many values a trait has (the renderer draws exactly these)
    function valuesOf(uint8 trait) internal pure returns (uint8) {
        return [3, 13, 4, 3, 6, 3, 10, 16][trait];
    }

    function _shift(uint8 trait) internal pure returns (uint8) {
        return [0, 2, 6, 8, 10, 13, 15, 19][trait];
    }

    function _bits(uint8 trait) internal pure returns (uint8) {
        return [2, 4, 2, 2, 3, 2, 4, 4][trait];
    }

    /// @notice One trait's value out of a combo
    function valueOf(uint24 combo, uint8 trait) internal pure returns (uint8) {
        return uint8((uint256(combo) >> _shift(trait)) & ((1 << _bits(trait)) - 1));
    }

    /// @notice Sets every value of one trait: its cap and the lowest tier that may take it. Before sealing only.
    function setTraitRules(uint8 trait, uint16[] calldata caps, uint8[] calldata minTiers) external onlyGovernor {
        if (traitsSealed) revert TraitsAreSealed();
        uint8 n = valuesOf(trait);
        if (caps.length != n || minTiers.length != n) revert BadTraits();
        for (uint8 v; v < n; ++v) {
            if (minTiers[v] > TIERS) revert BadTraits();
            _rules[uint256(trait) << 8 | v] = Rule(caps[v], 0, minTiers[v]);
        }
        _configured |= uint8(1 << trait);
    }

    /// @notice Adds a pair of values that together need a higher tier. Before sealing only.
    function addPairRule(PairRule calldata p) external onlyGovernor {
        if (traitsSealed) revert TraitsAreSealed();
        if (_pairs.length >= MAX_PAIR_RULES || p.traitA >= TRAITS || p.traitB >= TRAITS || p.minTier > TIERS) revert BadTraits();
        if (p.valueA >= valuesOf(p.traitA) || p.valueB >= valuesOf(p.traitB)) revert BadTraits();
        _pairs.push(p);
    }

    /// @notice Locks the rules: every trait set, and the characters' caps add up to the supply.
    function sealTraits() external onlyGovernor {
        if (traitsSealed) revert TraitsAreSealed();
        if (_configured != type(uint8).max) revert BadTraits();
        uint256 chars;
        for (uint8 v; v < valuesOf(CHARACTER); ++v) chars += _rules[v].cap;
        if (chars != SUPPLY) revert BadTraits();
        traitsSealed = true;
        emit TraitsSealed();
    }

    /// @notice Lets lower tiers take a value nobody above them did: it can only ever go down, never up.
    function lowerMinTier(uint8 trait, uint8 value, uint8 minTier) external onlyGovernor {
        Rule storage r = _rules[uint256(trait) << 8 | value];
        if (trait >= TRAITS || value >= valuesOf(trait) || minTier >= r.minTier) revert BadTraits();
        r.minTier = minTier;
        emit MinTierLowered(trait, value, minTier);
    }

    function ruleOf(uint8 trait, uint8 value) external view returns (Rule memory) {
        return _rules[uint256(trait) << 8 | value];
    }

    function pairRules() external view returns (PairRule[] memory) {
        return _pairs;
    }

    /* ── tiers ──────────────────────────────────────────────────── */

    /// @notice What an account's bag reaches today: the best of its $IMD, its IMD6900 and its identity.md NFTs
    function tierOf(address account) public view returns (uint8) {
        (uint256 a, uint256 b, uint256 c) = _bag(account);
        return _tier(a, b, c);
    }

    /// @dev The tier a mint or a claim counts: never while v4's PoolManager is unlocked (a flash loan of its $IMD)
    function _lockedTierOf(address account) internal view returns (uint8) {
        if (POOL_MANAGER.code.length != 0 && IExttloadMin(POOL_MANAGER).exttload(UNLOCKED_SLOT) != 0) revert Flash();
        return tierOf(account);
    }

    function _bag(address account) internal view returns (uint256, uint256, uint256) {
        return (IERC20Min(imd).balanceOf(account), IERC20Min(imd6900).balanceOf(account), IERC20Min(identity).balanceOf(account));
    }

    function _tier(uint256 a, uint256 b, uint256 c) internal view returns (uint8) {
        for (uint8 t = TIERS; t > 0; --t) {
            if (a >= imdTier[t - 1] || b >= imd6900Tier[t - 1] || c >= identityTier[t - 1]) return t;
        }
        return 0;
    }

    /// @notice The lowest tier that may take a combo: the highest any of its values or pairs needs
    function _tierNeeded(uint24 combo) internal view returns (uint8 tier) {
        for (uint8 t; t < TRAITS; ++t) {
            uint8 m = _rules[uint256(t) << 8 | valueOf(combo, t)].minTier;
            if (m > tier) tier = m;
        }
        for (uint256 i; i < _pairs.length; ++i) {
            PairRule memory p = _pairs[i];
            if (valueOf(combo, p.traitA) == p.valueA && valueOf(combo, p.traitB) == p.valueB && p.minTier > tier) tier = p.minTier;
        }
    }

    /// @notice Whether a combo can be minted for this tier now: 0 yes, 1 not a fren, 2 taken, 3 a trait is sold out,
    ///         4 the tier is too low. The relayer checks before it signs; claim checks again.
    function check(uint24 combo, uint8 tier) public view returns (uint8 code) {
        if (combo >> 23 != 0) return 1;
        for (uint8 t; t < TRAITS; ++t) if (valueOf(combo, t) >= valuesOf(t)) return 1;
        if (valueOf(combo, CHARACTER) != 0 && valueOf(combo, HAT) != 0) return 1; // hats fit only the cyborg pepe
        if (taken[combo]) return 2;
        for (uint8 t; t < TRAITS; ++t) {
            Rule storage r = _rules[uint256(t) << 8 | valueOf(combo, t)];
            if (r.minted >= r.cap) return 3;
        }
        if (_tierNeeded(combo) > tier) return 4;
    }

    /* ── minting ─────────────────────────────────────────────────── */

    /// @notice The n-th fren's price (n from 0): the curve's table
    function priceOf(uint256 n) external view returns (uint256) {
        return _prices(n, 1);
    }

    /// @notice What the next `count` frens cost together, now: the curve's price, and never less than the floor, their
    ///         share of it at what its IMD6900 costs (see FrenSwapper.floorRate). So nobody can mint and sell straight
    ///         back to the floor for more than they paid: they'd get back the floor less their share of the job.
    function quote(uint256 count) public view returns (uint256 price) {
        if (count == 0 || totalMinted + count > SUPPLY) revert SoldOut();
        price = _prices(totalMinted, count);
        uint256 out = totalMinted - inTreasury();
        if (out != 0) {
            uint256 value = floorImd;
            if (reserve != 0) value += reserve * 1e18 / IFrenSwapper(swapper).floorRate();
            uint256 atFloor = count * value / out;
            if (atFloor > price) price = atFloor;
        }
    }

    function _prices(uint256 from, uint256 count) internal view returns (uint256 total) {
        address t = priceTable;
        assembly ("memory-safe") {
            let m := mload(0x40)
            extcodecopy(t, m, add(1, mul(3, from)), mul(3, count))
            for { let i := 0 } lt(i, count) { i := add(i, 1) } { total := add(total, shr(232, mload(add(m, mul(3, i))))) }
        }
        total *= PRICE_UNIT;
    }

    /// @notice Mints `count` frens, unrevealed, at the curve's price (at most `maxPay` $IMD); one job builds them all.
    ///         The bag left after paying sets the tier the agents build for, and how many one request may ask for.
    function requestMint(uint8 count, uint256 maxPay) external returns (uint256) {
        return requestMintFor(msg.sender, count, maxPay);
    }

    /// @notice The same, paid by the caller for `minter` (how FrenMinter mints for ETH): the frens and the tier are the
    ///         minter's.
    function requestMintFor(address minter, uint8 count, uint256 maxPay) public nonReentrant returns (uint256 requestId) {
        // before opening only the owner mints (the strategy's first frens); after, the workers' window comes first
        if (!mintOpen && msg.sender != governor) revert MintClosed();
        if (!traitsSealed) revert TraitsNotSealed();
        // never into the treasury: its frens would take the tier of the floor's own bag, for anyone to buy out
        if (count == 0 || count > MAX_PER_REQUEST || minter == address(0) || minter == address(this)) revert BadRequest();
        if (mintOpen && workerGate != address(0)) IWorkerGate(workerGate).spend(minter, count);
        uint256 paid = quote(count);
        if (paid > maxPay) revert Cap();
        SafeTransferLib.safeTransferFrom(imd, msg.sender, address(this), paid);
        uint8 tier = _lockedTierOf(minter);
        if (count > maxMint[tier]) revert OverTierLimit(maxMint[tier]);
        bool lowTier = tier < _rules[uint256(CHARACTER) << 8 | 1].minTier && tier < _rules[uint256(CHARACTER) << 8 | 2].minTier;
        if (lowTier) {
            // below mumu and bobo this request can only become pepes: make sure enough are left for it
            Rule storage pepe = _rules[uint256(CHARACTER) << 8];
            if (pepe.minted + openLowTier + count > pepe.cap) revert SoldOut();
            openLowTier += count;
        }
        jobBudget += JOB_PRICE;
        floorImd += paid - JOB_PRICE;
        requestId = nextRequestId++;
        uint256 first = totalMinted + 1;
        totalMinted += count;
        requests[requestId] = Request(minter, tier, lowTier, false, count, 0, 1, uint32(first), 0, 0);
        for (uint256 i; i < count; ++i) _mint(minter, first + i);
        emit FrensMinted(requestId, minter, first, count, tier, paid);
        _buyFloor(0); // the floor's share into IMD6900 now, if this block hasn't bought yet
    }

    // The relayer's voucher: this request becomes these combos, built by this IMD job
    bytes32 internal constant VOUCHER_TYPEHASH =
        keccak256("FrenVoucher(uint256 requestId,uint24[] combos,bytes32 jobId,bytes32 outputHash,uint256 deadline)");

    function voucherDigest(uint256 requestId, uint24[] calldata combos, string calldata jobId, bytes32 outputHash, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IMD6900 Frens"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
        // EIP-712 hashes an array of uint24 as its elements, each padded to 32 bytes (what encodePacked does to arrays)
        bytes32 structHash = keccak256(
            abi.encode(VOUCHER_TYPEHASH, requestId, keccak256(abi.encodePacked(combos)), keccak256(bytes(jobId)), outputHash, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @notice Reveals a request's frens as the agents built them: the voucher names one combo per fren, and this
    ///         reveals them up to `upTo` (all, or a part: a big request reveals in parts, each under a transaction's gas
    ///         cap). Later parts may come with a newer voucher from the relayer (if a combo got taken meanwhile) but
    ///         must agree on the frens already revealed. Anyone may send it. The tier is the request's, from the mint.
    function reveal(
        uint256 requestId,
        uint24[] calldata combos,
        string calldata jobId,
        bytes32 outputHash,
        uint256 deadline,
        bytes calldata sig,
        uint256 upTo
    ) external nonReentrant {
        Request storage r = requests[requestId];
        uint256 from = r.revealed;
        if (combos.length != r.count || upTo <= from || upTo > r.count) revert BadRequest();
        if (block.timestamp > deadline) revert BadVoucher();
        if (!SignatureChecker.isValidSignatureNow(relayer, voucherDigest(requestId, combos, jobId, outputHash, deadline), sig)) {
            revert BadVoucher();
        }
        bytes32 h;
        for (uint256 i; i < from; ++i) h = keccak256(abi.encode(h, combos[i]));
        if (h != revealedHashOf[requestId]) revert BadVoucher(); // not the frens already revealed
        if (r.lowTier) openLowTier -= upTo - from;
        r.revealed = uint8(upTo);
        Rule storage pepe = _rules[uint256(CHARACTER) << 8];
        for (uint256 i = from; i < upTo; ++i) {
            uint24 combo = combos[i];
            uint8 code = check(combo, r.tier); // each reveal counts against the caps before the next is checked
            if (code != 0) revert BadCombo(code);
            // the pepes held for unrevealed low-tier frens (this request's later parts included) stay held
            if (valueOf(combo, CHARACTER) == 0 && pepe.minted + openLowTier >= pepe.cap) revert BadCombo(3);
            h = keccak256(abi.encode(h, combo));
            taken[combo] = true;
            for (uint8 t; t < TRAITS; ++t) ++_rules[uint256(t) << 8 | valueOf(combo, t)].minted;
            uint256 tokenId = r.firstToken + i;
            comboOf[tokenId] = combo;
            seedOf[tokenId] = uint256(keccak256(abi.encode(outputHash, requestId, combo))) | 1;
            emit Revealed(requestId, tokenId, combo, jobId, outputHash);
        }
        revealedHashOf[requestId] = h;
        if (upTo == r.count && r.jobs != 0) {
            // jobs paid for that it didn't need (a retry paid while the last one landed): their $IMD feeds the floor
            uint256 left = r.jobs * JOB_PRICE;
            r.jobs = 0;
            jobBudget -= left;
            floorImd += left;
        }
    }

    /// @notice Pays another job for a request whose frens aren't revealed yet (its last job didn't land): 0.50 $IMD,
    ///         anyone may (a holder of one of its frens, usually). The relayer posts it; the frens reveal when it lands.
    function retryJob(uint256 requestId) external nonReentrant {
        Request storage r = requests[requestId];
        if (r.revealed == r.count || r.jobs != 0) revert BadJob(); // nothing to reveal, or a job already paid for
        SafeTransferLib.safeTransferFrom(imd, msg.sender, address(this), JOB_PRICE);
        r.jobs = 1;
        jobBudget += JOB_PRICE;
        emit JobPaid(requestId, msg.sender);
    }

    /* ── the job payment: the contract signs exactly one, per request ── */

    struct Quote {
        string resource;
        bytes32 requesterScopeHash;
        string quoteId;
        bytes32 quoteHash;
        bytes32 paymentHash;
        string action;
        uint256 expiresAt;
    }

    /// @notice Approves a request's next job payment, one it has paid for: JOB_PRICE of $IMD to `imdPayTo` through the
    ///         x402 proxy, with this Permit2 nonce and deadline. It also approves IMD's quote approval for the same
    ///         payment. After this, IMD can settle it; nothing else can. A payment IMD never took and can't any more
    ///         is undone first, and its job money used again.
    function approveJob(uint256 requestId, uint256 nonce, uint256 deadline, Quote calldata q)
        external
        onlyKeeper
        returns (bytes32 permitDigest, bytes32 quoteDigest)
    {
        Request storage r = requests[requestId];
        if (r.revealed == r.count) revert BadJob();
        if (deadline > block.timestamp + 1 hours || q.expiresAt > block.timestamp + 1 hours) revert BadJob();
        if (r.jobApproved && !_spent(r.jobNonce)) {
            if (block.timestamp <= r.jobDeadline) revert BadJob(); // the last payment can still be taken
            _unapprove(r);
            ++r.jobs;
            jobBudget += JOB_PRICE;
        }
        if (r.jobs == 0) revert BadJob(); // the last job ran: another needs paying (retryJob)
        --r.jobs;
        r.jobApproved = true;
        r.jobNonce = nonce;
        r.jobDeadline = uint40(deadline);
        jobBudget -= JOB_PRICE;
        permitDigest = _permit2Digest(nonce, deadline);
        quoteDigest = _quoteApprovalDigest(q);
        approvedDigest[permitDigest] = true;
        approvedDigest[quoteDigest] = true;
        // Permit2 pulls from us with our "signature": let it move this one payment
        uint256 a = IERC20Min(imd).allowance(address(this), permit2);
        SafeTransferLib.safeApprove(imd, permit2, a + JOB_PRICE);
        emit JobApproved(requestId, nonce, deadline, permitDigest, quoteDigest);
    }

    function _spent(uint256 nonce) internal view returns (bool) {
        return IPermit2Min(permit2).nonceBitmap(address(this), nonce >> 8) & (1 << (nonce & 0xff)) != 0;
    }

    function _unapprove(Request storage r) internal {
        r.jobApproved = false;
        approvedDigest[_permit2Digest(r.jobNonce, r.jobDeadline)] = false;
        uint256 a = IERC20Min(imd).allowance(address(this), permit2);
        SafeTransferLib.safeApprove(imd, permit2, a > JOB_PRICE ? a - JOB_PRICE : 0);
    }

    /// @notice ERC-1271: valid only for the payments approveJob approved.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return approvedDigest[hash] ? ERC1271_MAGIC : bytes4(0xffffffff);
    }

    // Permit2's PermitWitnessTransferFrom as the x402 "exact" scheme signs it: the token, the amount, the proxy as
    // spender, and the payee in the witness.
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 internal constant WITNESS_TYPEHASH = keccak256("Witness(address to,uint256 validAfter)");
    bytes32 internal constant PERMIT_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Witness witness)TokenPermissions(address token,uint256 amount)Witness(address to,uint256 validAfter)"
    );

    function _permit2Digest(uint256 nonce, uint256 deadline) internal view returns (bytes32) {
        bytes32 perms = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, imd, JOB_PRICE));
        bytes32 witness = keccak256(abi.encode(WITNESS_TYPEHASH, imdPayTo, uint256(0)));
        bytes32 structHash = keccak256(abi.encode(PERMIT_WITNESS_TYPEHASH, perms, x402Proxy, nonce, deadline, witness));
        return keccak256(abi.encodePacked("\x19\x01", IPermit2Min(permit2).DOMAIN_SEPARATOR(), structHash));
    }

    // IMD's QuoteApproval (domain "IdentityMD Paid Action", version 1, no verifying contract)
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "QuoteApproval(string resource,bytes32 requesterScopeHash,string quoteId,bytes32 quoteHash,bytes32 paymentHash,string action,address asset,uint256 amount,address payTo,uint256 expiresAt)"
    );

    function _quoteApprovalDigest(Quote calldata q) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId)"),
                keccak256("IdentityMD Paid Action"),
                keccak256("1"),
                block.chainid
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                keccak256(bytes(q.resource)),
                q.requesterScopeHash,
                keccak256(bytes(q.quoteId)),
                q.quoteHash,
                q.paymentHash,
                keccak256(bytes(q.action)),
                imd,
                JOB_PRICE,
                imdPayTo,
                q.expiresAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /* ── the floor ──────────────────────────────────────────────── */

    /// @notice The floor, per fren out in the world: its share of the IMD6900 reserve and of the $IMD waiting to be
    ///         bought into it. recycle pays exactly this, revealed or not.
    function floorPerFren() public view returns (uint256 imd6900Part, uint256 imdPart) {
        uint256 out = totalMinted - inTreasury();
        if (out == 0) out = 1; // with every fren in the treasury, one bought back costs twice all of it, never nothing
        (imd6900Part, imdPart) = (reserve / out, floorImd / out);
    }

    /// @notice Buys the waiting $IMD into the reserve on the IMD6900/$IMD pool: up to maxImdPerBuy, one buy a block.
    ///         The swapper stops the buy once it has moved the price by half the pool's fee: a sandwich pays that fee
    ///         twice, so none can profit, whatever minOut says. What's left waits for the next buy. Mints buy as they
    ///         come; anyone may call this for what's still waiting (the arb bot does).
    function buyFloor(uint256 minOut) external nonReentrant {
        if (!_buyFloor(minOut)) revert Cap();
    }

    function _buyFloor(uint256 minOut) internal returns (bool) {
        uint256 imdIn = floorImd < maxImdPerBuy ? floorImd : maxImdPerBuy;
        if (imdIn == 0 || swapper == address(0) || block.number < lastFloorBuyBlock + buyDelayBlocks) return false;
        lastFloorBuyBlock = block.number;
        uint256 before = IERC20Min(imd6900).balanceOf(address(this));
        uint256 imdBefore = IERC20Min(imd).balanceOf(address(this));
        // the swapper pulls what it spends, never more than this buy; if the swap fails nothing moves, and a mint
        // still goes through. It always gets its gas: a wallet's estimate would otherwise find the cheapest way through,
        // the swap failing for want of it
        if (gasleft() < FLOOR_BUY_GAS + 50_000) revert SwapShort();
        SafeTransferLib.safeApprove(imd, swapper, imdIn);
        try IFrenSwapper(swapper).imdToImd6900{gas: FLOOR_BUY_GAS}(imdIn, minOut, address(this)) {} catch { return false; }
        uint256 spent = imdBefore - IERC20Min(imd).balanceOf(address(this));
        floorImd -= spent;
        uint256 got = IERC20Min(imd6900).balanceOf(address(this)) - before;
        if (got < minOut) revert SwapShort();
        reserve += got;
        _checkReserve();
        emit FloorBought(spent, 0, got, reserve);
        return true;
    }

    /// @notice Buys the ETH that arrived here — the pool's fee share and marketplace royalties — into the reserve,
    ///         through $IMD: ETH -> $IMD on IMD's pool (POOL4) -> IMD6900 (the swapper's route).
    /// @dev Anyone, on the same terms as {buyFloor}: both swaps stop at their price limits. $IMD a swap leaves waits
    ///      in floorImd, ETH stays here. It keeps its own one-a-block pace, so a dust buy can't take the mints' turn;
    ///      the two in one block move the pair pool one fee at most, which a sandwich pays twice.
    function buyFloorWithEth(uint256 ethIn, uint256 minOut) external nonReentrant {
        _buyGate();
        if (ethIn == 0 || ethIn > address(this).balance || ethIn > maxEthPerBuy) revert Cap();
        uint256 before = IERC20Min(imd6900).balanceOf(address(this));
        uint256 imdBefore = IERC20Min(imd).balanceOf(address(this));
        IFrenSwapper(swapper).ethToImd6900{value: ethIn}(minOut, address(this));
        floorImd += IERC20Min(imd).balanceOf(address(this)) - imdBefore;
        _credit(IERC20Min(imd6900).balanceOf(address(this)) - before, minOut, 0, ethIn);
    }

    function _buyGate() internal {
        if (block.number < lastEthBuyBlock + buyDelayBlocks) revert TooSoon();
        lastEthBuyBlock = block.number;
    }

    /// @notice Turns royalties paid in WETH (how most marketplaces pay) into the ETH {buyFloorWithEth} spends.
    function unwrapWeth() external nonReentrant returns (uint256 amount) {
        amount = IWethMin(WETH).balanceOf(address(this));
        if (amount == 0) revert NothingToUnwrap();
        IWethMin(WETH).withdraw(amount);
        emit WethUnwrapped(amount);
    }

    function _credit(uint256 got, uint256 minOut, uint256 imdIn, uint256 ethIn) internal {
        if (got < minOut || got == 0) revert SwapShort();
        reserve += got;
        _checkReserve();
        emit FloorBought(imdIn, ethIn, got, reserve);
    }

    /// @notice Sells a fren to the treasury for the floor: its share of the IMD6900 reserve and of the waiting $IMD.
    ///         Any holder, any time.
    function recycle(uint256 tokenId) external nonReentrant returns (uint256 paid, uint256 imdPaid) {
        if (ownerOf(tokenId) != msg.sender) revert NotHolder();
        (paid, imdPaid) = floorPerFren();
        _transfer(msg.sender, address(this), tokenId);
        reserve -= paid;
        floorImd -= imdPaid;
        // IMD6900 refuses a transfer of nothing (and a floor can be all one part): send only what there is
        if (paid != 0) SafeTransferLib.safeTransfer(imd6900, msg.sender, paid);
        if (imdPaid != 0) SafeTransferLib.safeTransfer(imd, msg.sender, imdPaid);
        _checkReserve();
        emit Recycled(tokenId, msg.sender, paid, imdPaid);
    }

    /// @notice Buys a fren from the treasury at twice the floor, both parts. All of it stays in the floor: it rises.
    function buyTreasury(uint256 tokenId, uint256 maxPay, uint256 maxImd) external nonReentrant returns (uint256 paid, uint256 imdPaid) {
        if (ownerOf(tokenId) != address(this)) revert NotInTreasury();
        (paid, imdPaid) = floorPerFren();
        (paid, imdPaid) = (2 * paid, 2 * imdPaid);
        if (paid > maxPay || imdPaid > maxImd) revert Cap();
        if (paid != 0) SafeTransferLib.safeTransferFrom(imd6900, msg.sender, address(this), paid);
        if (imdPaid != 0) SafeTransferLib.safeTransferFrom(imd, msg.sender, address(this), imdPaid);
        reserve += paid;
        floorImd += imdPaid;
        _transfer(address(this), msg.sender, tokenId);
        _checkReserve();
        emit TreasuryBought(tokenId, msg.sender, paid, imdPaid);
    }

    /// @notice Frens in the treasury: every fren this contract holds, recycled or sent here, all for sale (buyTreasury)
    function inTreasury() public view returns (uint256) {
        return balanceOf(address(this));
    }

    // Invariant R: the reserve is really here
    function _checkReserve() internal view {
        if (IERC20Min(imd6900).balanceOf(address(this)) < reserve) revert Invariant();
    }

    /* ── ERC-721C ────────────────────────────────────────────────── */

    function getTransferValidator() public view returns (address validator) {
        validator = _transferValidator;
        if (validator == address(0) && !_validatorSet) validator = DEFAULT_TRANSFER_VALIDATOR;
    }

    /// @notice The owner (the timelock) can move to another validator, or to address(0) to stop validating
    function setTransferValidator(address validator) external onlyCurator {
        if (validator != address(0) && validator.code.length == 0) revert InvalidTransferValidator();
        emit ICreatorToken.TransferValidatorUpdated(getTransferValidator(), validator);
        _validatorSet = true;
        _transferValidator = validator;
        _registerTokenType(validator);
    }

    function getTransferValidationFunction() external pure returns (bytes4 functionSignature, bool isViewFunction) {
        return (ITransferValidator721.validateTransfer.selector, true);
    }

    /// @dev Tells the validator this is an ERC-721, as Limit Break's base does; a validator without it is fine
    function _registerTokenType(address validator) internal {
        if (validator.code.length == 0) return;
        try ITransferValidator721(validator).setTokenTypeOfCollection(address(this), TOKEN_TYPE_ERC721) {} catch {}
    }

    /// @dev Every trade between holders goes past the validator. Mints and burns don't, and neither do the floor's own
    ///      moves (a fren recycled into the treasury, or bought out of it): no marketplace rule can block the floor.
    function _beforeTokenTransfer(address from, address to, uint256 id) internal view override {
        if (from == address(0) || to == address(0) || from == address(this) || to == address(this)) return;
        address validator = getTransferValidator();
        // no validator, or none deployed on this chain (a test chain): nothing to apply, never a frozen collection
        if (validator == address(0) || msg.sender == validator || validator.code.length == 0) return;
        ITransferValidator721(validator).validateTransfer(msg.sender, from, to, id);
    }

    /* ── royalties (ERC-2981) ────────────────────────────────────── */

    /// @notice Every marketplace that honours ERC-2981 pays the royalty to this contract, where it joins the floor.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (address(this), (salePrice * royaltyBps) / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        // ERC-2981 royalties, ERC-721C
        return interfaceId == 0x2a55205a || interfaceId == type(ICreatorToken).interfaceId
            || interfaceId == type(ICreatorTokenLegacy).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice The pool's fee share, marketplace royalties and WETH unwrapped here all arrive as ETH; it only ever
    ///         leaves bought into the reserve.
    receive() external payable {}

    /* ── settings ────────────────────────────────────────────────── */

    /// @notice The keeper, the relayer and IMD's payee for jobs; address(0) leaves one as it is
    function setRoles(address keeper_, address relayer_, address imdPayTo_) external onlyGovernor {
        if (keeper_ != address(0)) keeper = keeper_;
        if (relayer_ != address(0)) relayer = relayer_;
        if (imdPayTo_ != address(0)) imdPayTo = imdPayTo_;
        emit Setting("roles", 0, address(0));
    }

    /// @notice The art (the collection's look, like its page): the owner can adjust it at once until it's frozen
    function setRenderer(address r) external onlyCurator {
        if (artFrozen) revert Unauthorized();
        renderer = r;
        emit Setting("renderer", 0, r);
    }

    /// @notice Freezes the art for good: no renderer change after this
    function freezeArt() external onlyCurator {
        artFrozen = true;
        emit Setting("artFrozen", 1, renderer);
    }

    /// @notice The modules: the swapper that buys the floor, and the workers' window (address(0): none)
    function setModules(address swapper_, address workerGate_) external onlyGovernor {
        (swapper, workerGate) = (swapper_, workerGate_);
        emit Setting("modules", uint160(workerGate_), swapper_);
    }

    /// @notice The tiers' thresholds, lowest tier first; each must not fall from one tier to the next
    function setTiers(uint256[TIERS] calldata imd_, uint256[TIERS] calldata imd6900_, uint256[TIERS] calldata identity_)
        external
        onlyGovernor
    {
        for (uint256 i = 1; i < TIERS; ++i) {
            if (imd_[i] < imd_[i - 1] || imd6900_[i] < imd6900_[i - 1] || identity_[i] < identity_[i - 1]) revert BadTraits();
        }
        imdTier = imd_;
        imd6900Tier = imd6900_;
        identityTier = identity_;
        emit Setting("tiers", 0, address(0));
    }

    /// @notice How many frens one request may ask for, by tier: never fewer for a higher tier, 1 to 69
    function setMaxMint(uint8[TIERS + 1] calldata m) external onlyGovernor {
        for (uint256 i; i <= TIERS; ++i) {
            if (m[i] == 0 || m[i] > MAX_PER_REQUEST || (i > 0 && m[i] < m[i - 1])) revert BadTraits();
        }
        maxMint = m;
        emit Setting("maxMint", m[TIERS], address(0));
    }

    /// @notice The blocks between floor buys, and the most one floor buy spends ($IMD, ETH)
    function setParams(uint256 buyDelayBlocks_, uint256 imdCap, uint256 ethCap) external onlyGovernor {
        (buyDelayBlocks, maxImdPerBuy, maxEthPerBuy) = (buyDelayBlocks_, imdCap, ethCap);
        emit Setting("params", buyDelayBlocks_, address(0));
    }

    /// @notice The marketplace royalty (ERC-2981), at most 10%: always paid to this contract, where it buys the floor
    function setRoyalty(uint96 bps) external onlyCurator {
        if (bps > 1_000) revert Cap();
        royaltyBps = bps;
        emit Setting("royalty", bps, address(0));
    }

    /// @notice Hands the mint's and the floor's settings on (to the timelock): the owner keeps the collection
    function setGovernor(address g) external onlyGovernor {
        if (g == address(0)) revert Unauthorized();
        governor = g;
        emit Setting("governor", 0, g);
    }

    function setMintOpen(bool open) external onlyGovernor {
        mintOpen = open;
        emit Setting("mintOpen", open ? 1 : 0, address(0));
    }
}
