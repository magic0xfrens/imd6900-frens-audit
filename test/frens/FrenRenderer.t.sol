// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenArt, FrenRenderer} from "../../src/frens/FrenRenderer.sol";

/// @notice The on-chain renderer draws exactly what the reference (export_v2.py in the art kit) draws, and the art can be
///         written in transactions under EIP-7825's cap.
contract FrenRendererTest is Test {
    string constant ART = "script/frens/art/";
    uint256 constant TX_CAP = 1 << 24; // EIP-7825
    uint256 constant BATCH = 36_000; // bytes of art per transaction, as script/frens/DeployFrens.s.sol

    FrenArt art;
    FrenRenderer r;
    bytes[] data;
    uint256 maxBatchGas;

    function setUp() public {
        art = new FrenArt();
        string[] memory names = vm.parseJsonStringArray(vm.readFile(string.concat(ART, "manifest.json")), ".layers");
        for (uint256 i; i < names.length; ++i) data.push(vm.readFileBinary(string.concat(ART, "layers/", names[i], ".bin")));
        address[] memory ptrs = _writeAll(data);
        bytes[] memory pal = new bytes[](1);
        pal[0] = vm.readFileBinary(string.concat(ART, "palette.bin"));
        r = new FrenRenderer(
            art.write(pal)[0], ptrs, vm.readFileBinary(string.concat(ART, "tables.bin")), vm.readFileBinary(string.concat(ART, "facetable.bin")),
            uint8(vm.parseJsonUint(vm.readFile(string.concat(ART, "manifest.json")), ".shadow"))
        );
    }

    /// @dev Writes the layers the way the deploy script does: batches of up to BATCH bytes.
    function _writeAll(bytes[] memory all) internal returns (address[] memory ptrs) {
        ptrs = new address[](all.length);
        uint256 i;
        while (i < all.length) {
            uint256 j = i;
            uint256 size;
            while (j < all.length && size + all[j].length <= BATCH) size += all[j++].length;
            bytes[] memory batch = new bytes[](j - i);
            for (uint256 k; k < batch.length; ++k) batch[k] = all[i + k];
            uint256 g = gasleft();
            address[] memory out = art.write(batch);
            uint256 used = g - gasleft();
            if (used > maxBatchGas) maxBatchGas = used;
            for (uint256 k; k < out.length; ++k) ptrs[i + k] = out[k];
            i = j;
        }
    }

    function test_MatchesTheReference() public view {
        string memory exp = vm.readFile(string.concat(ART, "expected.json"));
        uint256 i;
        for (; vm.keyExistsJson(exp, string.concat(".[", vm.toString(i), "]")); ++i) {
            string memory k = string.concat(".[", vm.toString(i), "]");
            uint24 combo = uint24(vm.parseJsonUint(exp, string.concat(k, ".combo")));
            uint256 seed = vm.parseUint(vm.parseJsonString(exp, string.concat(k, ".seed")));
            bytes32 want = vm.parseJsonBytes32(exp, string.concat(k, ".bmpSha256"));
            assertEq(sha256(r.bmp(combo, seed)), want, "the bitmap differs from the reference");
        }
        assertGe(i, 6);
    }

    /// @dev Each batch fits a transaction with room to spare (the call's own 21k + calldata ride on top).
    function test_ArtFitsTransactions() public {
        emit log_named_uint("largest batch gas", maxBatchGas);
        assertLt(maxBatchGas * 13 / 10, TX_CAP * 9 / 10); // forge pads its estimate by 30%
        uint256 total;
        for (uint256 i; i < data.length; ++i) total += data[i].length;
        emit log_named_uint("art bytes", total);
    }

    /// @dev Writing is by content: the same bytes land at the same address, a second write is a no-op.
    function test_ArtIsAddressedByContent() public {
        bytes[] memory one = new bytes[](1);
        one[0] = data[0];
        address p = art.pointer(data[0]);
        assertEq(art.write(one)[0], p);
        assertEq(r.layers()[0], p);
        assertEq(p.code.length, data[0].length + 1);
    }

    function test_TokenURIIsCheapEnoughToRead() public {
        // a mumu, gold coat, red lightsaber, on the lit machine wall
        uint24 combo = uint24(1 | 3 << 2 | 1 << 6 | 2 << 8 | 2 << 10 | 5 << 15 | 13 << 19);
        uint256 g = gasleft();
        string memory uri = r.tokenURI(2222, combo, 424242);
        uint256 used = g - gasleft();
        emit log_named_uint("tokenURI gas", used);
        emit log_named_uint("tokenURI bytes", bytes(uri).length);
        assertLt(used, 30_000_000);
        assertEq(bytes(uri)[0], "d");
    }

    function test_Attributes() public view {
        // bobo, face 10, cyan, black coat, red shirt, bobo hat, terminal, bunsen burner
        uint24 combo = uint24(2 | 10 << 2 | 2 << 6 | 1 << 8 | 1 << 10 | 2 << 13 | 7 << 15 | 15 << 19);
        assertEq(
            r.attributes(combo),
            '[{"trait_type":"Character","value":"Bobo"},{"trait_type":"Face","value":"Special"},{"trait_type":"Eye","value":"Cyan"},{"trait_type":"Coat","value":"Black"},{"trait_type":"Shirt","value":"Red"},{"trait_type":"Hat","value":"Bobo Hat"},{"trait_type":"Item","value":"Bunsen Burner"},{"trait_type":"Background","value":"Terminal"}]'
        );
        assertEq(
            r.attributes(0),
            '[{"trait_type":"Character","value":"Cyborg Pepe"},{"trait_type":"Face","value":"Classic"},{"trait_type":"Eye","value":"Green"},{"trait_type":"Coat","value":"White"},{"trait_type":"Shirt","value":"Blue"},{"trait_type":"Hat","value":"None"},{"trait_type":"Item","value":"None"},{"trait_type":"Background","value":"Matrix Green"}]'
        );
    }

    /// @dev The renderer draws only what the art has: anything else reverts rather than draws garbage.
    function test_RejectsCombosOutsideTheArt() public {
        uint24[6] memory bad = [uint24(3), uint24(13 << 2), uint24(3 << 8), uint24(6 << 10), uint24(3 << 13), uint24(10 << 15)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(FrenRenderer.Missing.selector);
            r.canvas(bad[i], 0);
        }
        r.canvas(uint24(2 | 12 << 2 | 3 << 6 | 2 << 8 | 5 << 10 | 2 << 13 | 9 << 15 | 15 << 19), 1); // every trait at its last value
    }

    /// @dev Each character's face is its own: mumu's classic isn't pepe's, and swapping faces changes the drawing.
    function test_FacesPerCharacter() public view {
        assertTrue(keccak256(r.canvas(0, 0)) != keccak256(r.canvas(1, 0)), "pepe and mumu differ");
        assertTrue(keccak256(r.canvas(1, 0)) != keccak256(r.canvas(1 | 1 << 2, 0)), "mumu's faces differ");
        assertTrue(keccak256(r.canvas(0, 0)) != keccak256(r.canvas(1 << 19, 0)), "the item shows");
    }

    function test_ConstructorChecksTheArt() public {
        address[] memory ptrs = r.layers();
        address pal = r.palette();
        bytes memory tables = vm.readFileBinary(string.concat(ART, "tables.bin"));
        bytes memory ft = vm.readFileBinary(string.concat(ART, "facetable.bin"));
        vm.expectRevert(FrenRenderer.BadArt.selector);
        new FrenRenderer(ptrs[0], ptrs, tables, ft, 2); // not a palette
        bytes memory badFt = bytes.concat(ft);
        badFt[0] = bytes1(uint8(r.faceLayers()));
        vm.expectRevert(FrenRenderer.BadArt.selector);
        new FrenRenderer(pal, ptrs, tables, badFt, 2); // a face that's not there
        address[] memory short = new address[](30);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        new FrenRenderer(pal, short, tables, ft, 2); // no faces
        ptrs[3] = address(0xdead);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        new FrenRenderer(pal, ptrs, tables, ft, 2); // a layer that isn't written
    }

    /// @dev Unrevealed: the classic pepe in one flat dark green, in the terminal, each token through its own window
    function test_UnrevealedIsASilhouette() public {
        bytes memory a = r.silhouette(7);
        uint256 shadow;
        for (uint256 i; i < a.length; ++i) if (uint8(a[i]) == r.shadow()) ++shadow;
        assertGt(shadow, 2000, "a pepe-sized silhouette");
        assertTrue(keccak256(a) != keccak256(r.silhouette(8)), "each token sees the terminal through its own window");
        bytes memory pal = vm.readFileBinary(string.concat(ART, "palette.bin"));
        uint256 c = r.shadow() * 4;
        assertEq(abi.encodePacked(pal[c + 2], pal[c + 1], pal[c]), hex"1b7822", "the dark lens green");
        uint256 g = gasleft();
        string memory uri = r.pendingURI(7);
        emit log_named_uint("pendingURI gas", g - gasleft());
        assertEq(bytes(uri)[0], "d");
    }

}
