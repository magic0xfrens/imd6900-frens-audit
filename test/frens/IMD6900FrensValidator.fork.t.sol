// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrensRules} from "./FrensRules.sol";

interface IValidator {
    function beforeAuthorizedTransfer(address operator, address token, uint256 tokenId) external;
}

interface IERC20 {
    function approve(address, uint256) external returns (bool);
}

/// @notice On a mainnet fork: the frens against Limit Break's live transfer validator, with the policy it gives a
///         new collection by default: a holder can send their own fren, an unlisted contract can't move one, and an
///         OpenSea sale (its zone authorizing the conduit's transfer) goes through. Needs MAINNET_RPC_URL.
contract IMD6900FrensValidatorForkTest is Test, FrensRules {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant IMD6900 = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant X402_PROXY = 0x402085c248EeA27D92E8b30b2C58ed07f9E20001;
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    uint256 constant RELAYER_KEY = 0xA11CE;
    address constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71; // Seaport's OpenSea conduit
    address constant OPENSEA_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100; // on the validator's default authorizer list

    IMD6900Frens frens;
    // fresh addresses: Foundry's makeAddr("alice") has a well-known key, and on mainnet someone gave it 7702 code
    address alice = address(uint160(uint256(keccak256("imd6900 frens fork alice"))));
    address bob = address(uint160(uint256(keccak256("imd6900 frens fork bob"))));
    address buyer = address(uint160(uint256(keccak256("imd6900 frens fork buyer"))));

    function setUp() public {
        // a mainnet fork: MAINNET_RPC_URL; without one (an offline machine) these tests skip
        string memory rpc_ = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        frens = new IMD6900Frens(address(this), IMD, IMD6900, IDENTITY, PERMIT2, X402_PROXY, makeAddr("payTo"), address(this), vm.addr(RELAYER_KEY), _flatPrices());
        _rules(frens, [uint16(1598), 312, 312]);
        frens.sealTraits();
        frens.setMintOpen(true);
        deal(IMD, alice, 1e18);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(frens), type(uint256).max);
        uint256 id = frens.requestMint(1, type(uint256).max);
        vm.stopPrank();
        // the relayer's voucher reveals alice's fren as a common pepe
        uint24[] memory combos = new uint24[](1);
        combos[0] = _combo(PEPE, 1, 0, 0, 2, 0, 7, 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(RELAYER_KEY, frens.voucherDigest(id, combos, "job", bytes32(0), deadline));
        frens.reveal(id, combos, "job", bytes32(0), deadline, abi.encodePacked(r, s_, v), combos.length);
    }

    function test_LiveValidatorGuardsTrades() public {
        address v = frens.getTransferValidator();
        assertEq(v, frens.DEFAULT_TRANSFER_VALIDATOR());
        assertGt(v.code.length, 0, "Limit Break's validator is live on mainnet");
        assertEq(frens.ownerOf(1), alice);
        assertEq(alice.code.length + bob.code.length + buyer.code.length, 0, "plain wallets");

        // the holder sending it themselves, from her own wallet (tx.origin too: the validator checks for plain EOAs)
        vm.prank(alice, alice);
        (bool otc,) = address(frens).call(abi.encodeCall(frens.transferFrom, (alice, bob, 1)));
        emit log_named_string("holder sends it herself (OTC)", otc ? "allowed" : "blocked");
        address holder = otc ? bob : alice;

        // a contract nobody whitelisted
        address rando = address(new Rando());
        vm.prank(holder);
        frens.setApprovalForAll(rando, true);
        vm.prank(rando, buyer);
        (bool randoOk,) = address(frens).call(abi.encodeCall(frens.transferFrom, (holder, buyer, 1)));
        emit log_named_string("an unlisted marketplace contract", randoOk ? "allowed" : "blocked");
        assertFalse(randoOk, "an operator off the list can't move a fren");

        // OpenSea's conduit on its own: not on the default whitelist
        vm.prank(holder);
        frens.setApprovalForAll(OPENSEA_CONDUIT, true);
        vm.prank(OPENSEA_CONDUIT, buyer);
        (bool bare,) = address(frens).call(abi.encodeCall(frens.transferFrom, (holder, buyer, 1)));
        emit log_named_string("OpenSea's conduit, unauthorized", bare ? "allowed" : "blocked");
        assertFalse(bare);

        // a real OpenSea sale: its zone, one of the validator's default authorizers, authorizes this transfer first,
        // then the conduit moves the fren in the same transaction
        vm.prank(OPENSEA_ZONE, buyer);
        IValidator(v).beforeAuthorizedTransfer(OPENSEA_CONDUIT, address(frens), 1);
        vm.prank(OPENSEA_CONDUIT, buyer);
        (bool sale,) = address(frens).call(abi.encodeCall(frens.transferFrom, (holder, buyer, 1)));
        emit log_named_string("OpenSea sale (zone-authorized)", sale ? "allowed" : "blocked");
        assertTrue(sale, "OpenSea can sell frens");
        assertEq(frens.ownerOf(1), buyer);
    }
}

contract Rando {}
