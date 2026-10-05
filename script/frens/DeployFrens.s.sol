// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FrenArt, FrenRenderer} from "../../src/frens/FrenRenderer.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrenSwapper} from "../../src/frens/FrenSwapper.sol";
import {FrenMinter} from "../../src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "../../src/frens/FrenWorkerGate.sol";

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
}

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes calldata initCode) external payable returns (address);
}

/// @notice Deploys the IMD6900 frens on Ethereum:
///  1. the art, through FrenArt in batches (each under EIP-7825's 2^24 gas per transaction), then the renderer;
///  2. the price curve's table (script/frens/price/prices.bin, through FrenArt), IMD6900Frens (owner: the deployer,
///     until the handover), its FrenSwapper, and FrenMinter (mint with ETH, through IMD's pool). On mainnet the frens
///     and the swapper go to addresses fixed ahead (the timelock batch names them) with CreateX's CREATE3: deployer-only
///     salts, the same address whatever the final code (tools/mine-frens-address.mjs mined them for 0x6900);
///  3. wires them and sets the launch trait rules, then seals them (they can never change, only a min tier go down).
///  The mint stays closed. Then, from the deployer:
///   - a test mint through the relayer (tools/fren-relayer.mjs), then setMintOpen(true);
///   - `handover(frens)`: ownership to the Ethereum timelock (settings take 48h from then).
///  The hook's fee changes are a timelock batch of their own (FrensTimelockBatch.s.sol).
///
///   FRENS_KEEPER=0x… FRENS_RELAYER=0x… forge script script/frens/DeployFrens.s.sol --rpc-url $MAINNET_RPC_URL \
///     --account imdstr-deployer --sender 0x35dA9C0303507ddf708E87F2568EdDf12c47a059 --broadcast --slow
///   forge script script/frens/DeployFrens.s.sol --sig "handover(address)" <frens> … --broadcast
contract DeployFrens is Script {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant IMD6900 = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address public constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant X402_PROXY = 0x402085c248EeA27D92E8b30b2C58ed07f9E20001;
    address public constant IMD_PAY_TO = 0x4e0fA57Bde726079356537E2F34d671E9F41ADbc; // IMD's payee for paid jobs
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant PAIR_HOOK = 0x667f4621030aCfAfb1bD0B64d33610A8567f2A44; // IMD6900/$IMD
    address public constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840; // IMD's ETH/$IMD
    address public constant TIMELOCK = 0xBd3ed9F4AbD9946cA6F59C8F13A3EbebDE1EA29D;
    address public constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address public constant DEPLOYER = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059; // the salts are its alone
    bytes32 public constant FRENS_SALT = 0x35da9c0303507ddf708e87f2568eddf12c47a059006672656e7300000004b760;
    address public constant FRENS_AT = 0x69004fEd3d8a34FFA952d15A128f74D8340fa79d;
    bytes32 public constant SWAPPER_SALT = 0x35da9c0303507ddf708e87f2568eddf12c47a05900737761707200000000e416;
    address public constant SWAPPER_AT = 0x6900D4a8a26C9B24978b5fC1341d8c811B374624;

    string internal constant ART = "script/frens/art/";
    uint256 internal constant BATCH = 36_000; // bytes of art per transaction (~8M gas: under EIP-7825's cap with forge's 30% margin)

    struct Deployed {
        FrenArt art;
        FrenRenderer renderer;
        IMD6900Frens frens;
        FrenSwapper swapper;
        address prices;
        FrenMinter minter;
        FrenWorkerGate gate;
    }

    function run() external returns (Deployed memory d) {
        address keeper = vm.envAddress("FRENS_KEEPER");
        address relayer = vm.envAddress("FRENS_RELAYER");
        vm.startBroadcast();
        require(msg.sender == DEPLOYER, "the fixed addresses belong to the deployer 0x35dA...a059");
        d = _deploy(msg.sender, keeper, relayer, true);
        vm.stopBroadcast();
        console2.log("FrenArt      ", address(d.art));
        console2.log("FrenRenderer ", address(d.renderer));
        console2.log("IMD6900Frens ", address(d.frens));
        console2.log("FrenSwapper  ", address(d.swapper));
        console2.log("FrenMinter   ", address(d.minter));
        console2.log("WorkerGate   ", address(d.gate));
        console2.log("price table  ", d.prices);
        console2.log("owner (until handover)", d.frens.owner());
    }

    /// @notice Before the opening, the owner mints `count` frens to the IMD6900 strategy (tier 3: it holds identity.md
    ///         NFTs), 69 a request, paid with the ETH sent: FrenMinter buys exactly their price in $IMD on POOL4 first.
    ///         The curve's first frens, ahead of the workers' window; their price, less the jobs, buys the floor.
    ///   forge script script/frens/DeployFrens.s.sol --sig "firstFrens(address,address,uint256,uint256)" <frens> <minter> \
    ///     <count> <ethIn> --rpc-url … --account imdstr-deployer --sender 0x35dA… --broadcast --slow
    function firstFrens(IMD6900Frens frens, FrenMinter minter, uint256 count, uint256 ethIn) external {
        require(!frens.mintOpen(), "before the opening only");
        uint256 cost;
        for (uint256 n = frens.totalMinted(); n < frens.totalMinted() + count; ++n) cost += frens.priceOf(n);
        cost += cost / 100; // the floor rule can lift a later request a little above the curve
        vm.startBroadcast();
        minter.buyImd{value: ethIn}(cost);
        IERC20Min(IMD).approve(address(frens), cost);
        for (uint256 left = count; left > 0;) {
            uint8 n = uint8(left > 69 ? 69 : left);
            frens.requestMintFor(IMD6900, n, type(uint256).max);
            left -= n;
        }
        IERC20Min(IMD).approve(address(frens), 0);
        vm.stopBroadcast();
        console2.log("frens minted to the strategy", count, "total minted", frens.totalMinted());
    }

    function handover(IMD6900Frens frens) external {
        vm.broadcast();
        frens.transferOwnership(TIMELOCK);
        console2.log("owner", frens.owner());
    }

    /// @dev Every step, from the test contract (the fork tests): plain deploys, no fixed addresses
    function deploy(address owner, address keeper, address relayer) public returns (Deployed memory d) {
        return _deploy(owner, keeper, relayer, false);
    }

    function _deploy(address owner, address keeper, address relayer, bool fixedAt) internal returns (Deployed memory d) {
        d.art = new FrenArt();
        d.renderer = writeArt(d.art);
        bytes[] memory table = new bytes[](1);
        table[0] = vm.readFileBinary("script/frens/price/prices.bin");
        d.prices = d.art.write(table)[0];
        bytes memory frensInit = abi.encodePacked(
            type(IMD6900Frens).creationCode,
            abi.encode(owner, IMD, IMD6900, IDENTITY, PERMIT2, X402_PROXY, IMD_PAY_TO, keeper, relayer, d.prices)
        );
        d.frens = IMD6900Frens(payable(_place(frensInit, fixedAt ? FRENS_SALT : bytes32(0), FRENS_AT)));
        bytes memory swapperInit = abi.encodePacked(
            type(FrenSwapper).creationCode, abi.encode(POOL_MANAGER, IMD, IMD6900, address(d.frens), PAIR_HOOK, POOL4_HOOK)
        );
        d.swapper = FrenSwapper(_place(swapperInit, fixedAt ? SWAPPER_SALT : bytes32(0), SWAPPER_AT));
        d.minter = new FrenMinter(POOL_MANAGER, address(d.frens), POOL4_HOOK, PAIR_HOOK);
        // the workers' window: its owner is the deployer, not the timelock, so it can open the public mint at once
        d.gate = new FrenWorkerGate(owner, address(d.frens), IDENTITY, IMD6900);
        d.frens.setRoles(address(0), address(0), address(0), address(d.renderer));
        d.frens.setModules(address(d.swapper), address(d.gate));
        launchRules(d.frens);
        d.frens.sealTraits();
    }

    /// @dev With a salt: CreateX's CREATE3, and it must land where the timelock batch expects. Without: a plain CREATE.
    function _place(bytes memory initCode, bytes32 salt, address expected) internal returns (address a) {
        if (salt == bytes32(0)) {
            assembly ("memory-safe") {
                a := create(0, add(initCode, 32), mload(initCode))
            }
            require(a != address(0), "deploy failed");
            return a;
        }
        a = ICreateX(CREATEX).deployCreate3(salt, initCode);
        require(a == expected, "not at the address the timelock batch names");
    }

    function writeArt(FrenArt art) public returns (FrenRenderer) {
        string memory manifest = vm.readFile(string.concat(ART, "manifest.json"));
        string[] memory names = vm.parseJsonStringArray(manifest, ".layers");
        address[] memory ptrs = new address[](names.length);
        uint256 i;
        while (i < names.length) {
            uint256 j = i;
            uint256 size;
            bytes[] memory buf = new bytes[](names.length);
            while (j < names.length) {
                bytes memory b = vm.readFileBinary(string.concat(ART, "layers/", names[j], ".bin"));
                if (j > i && size + b.length > BATCH) break;
                buf[j - i] = b;
                size += b.length;
                ++j;
            }
            bytes[] memory batch = new bytes[](j - i);
            for (uint256 k; k < batch.length; ++k) batch[k] = buf[k];
            address[] memory out = art.write(batch);
            for (uint256 k; k < out.length; ++k) ptrs[i + k] = out[k];
            i = j;
        }
        bytes[] memory pal = new bytes[](1);
        pal[0] = vm.readFileBinary(string.concat(ART, "palette.bin"));
        return new FrenRenderer(
            art.write(pal)[0], ptrs, vm.readFileBinary(string.concat(ART, "tables.bin")), vm.readFileBinary(string.concat(ART, "facetable.bin")),
            uint8(vm.parseJsonUint(vm.readFile(string.concat(ART, "manifest.json")), ".shadow"))
        );
    }

    /// @notice The launch rules (tools/fren-job.mjs launchRules() mirrors them; test/frens/FrensRules.sol too):
    ///  - characters 1598 cyborg pepe / 312 mumu / 312 bobo, mumu and bobo from tier 2;
    ///  - laser eyes (56) tier 3; gold lens (222), gold coat (103) tier 1; hats (266 each) tier 1;
    ///  - items 140 each, six common ones open to all, the rest tier 1, the two lightsabers (56 each) tier 3;
    ///  - a gold-coat mumu or bobo tier 3.
    function launchRules(IMD6900Frens f) public {
        (uint16[] memory c, uint8[] memory t) = _fill(3, 0, 0);
        (c[0], c[1], c[2], t[1], t[2]) = (1598, 312, 312, 2, 2);
        f.setTraitRules(0, c, t);
        (c, t) = _fill(13, 2222, 0);
        (c[12], t[12]) = (56, 3);
        f.setTraitRules(1, c, t);
        (c, t) = _fill(4, 2222, 0);
        (c[3], t[3]) = (222, 1);
        f.setTraitRules(2, c, t);
        (c, t) = _fill(3, 2222, 0);
        (c[2], t[2]) = (103, 1);
        f.setTraitRules(3, c, t);
        (c, t) = _fill(6, 2222, 0);
        f.setTraitRules(4, c, t);
        (c, t) = _fill(3, 266, 1);
        (c[0], t[0]) = (2222, 0);
        f.setTraitRules(5, c, t);
        (c, t) = _fill(10, 2222, 0);
        f.setTraitRules(6, c, t);
        (c, t) = _fill(16, 140, 1);
        (c[0], t[0]) = (2222, 0);
        for (uint256 i; i < 6; ++i) t[[1, 3, 4, 10, 11, 14][i]] = 0;
        (c[12], t[12], c[13], t[13]) = (56, 3, 56, 3);
        f.setTraitRules(7, c, t);
        f.addPairRule(IMD6900Frens.PairRule(0, 1, 3, 2, 3));
        f.addPairRule(IMD6900Frens.PairRule(0, 2, 3, 2, 3));
    }

    function _fill(uint8 n, uint16 cap, uint8 tier) internal pure returns (uint16[] memory caps, uint8[] memory tiers) {
        caps = new uint16[](n);
        tiers = new uint8[](n);
        for (uint8 i; i < n; ++i) (caps[i], tiers[i]) = (cap, tier);
    }
}
