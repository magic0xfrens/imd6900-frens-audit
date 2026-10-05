// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrensRules} from "./FrensRules.sol";

interface ISignatureTransfer {
    struct TokenPermissions { address token; uint256 amount; }
    struct PermitTransferFrom { TokenPermissions permitted; uint256 nonce; uint256 deadline; }
    struct SignatureTransferDetails { address to; uint256 requestedAmount; }
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice On a mainnet fork: the real Permit2 settles a job payment the frens contract "signed" through ERC-1271,
///         the way IMD's x402 proxy settles it, and refuses any other payment.
contract IMD6900FrensPermit2ForkTest is Test, FrensRules {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant IMD6900 = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant X402_PROXY = 0x402085c248EeA27D92E8b30b2C58ed07f9E20001;
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    string constant WITNESS_TYPE = "Witness witness)TokenPermissions(address token,uint256 amount)Witness(address to,uint256 validAfter)";
    bytes32 constant WITNESS_TYPEHASH = keccak256("Witness(address to,uint256 validAfter)");

    IMD6900Frens frens;
    address payTo = makeAddr("imdPayTo");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    uint256 id;

    function setUp() public {
        // a mainnet fork: MAINNET_RPC_URL; without one (an offline machine) these tests skip
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        frens = new IMD6900Frens(address(this), IMD, IMD6900, IDENTITY, PERMIT2, X402_PROXY, payTo, keeper, makeAddr("relayer"), _flatPrices());
        _rules(frens, [uint16(1598), 312, 312]);
        frens.sealTraits();
        frens.setMintOpen(true);
        deal(IMD, alice, 10e18);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(frens), type(uint256).max);
        id = frens.requestMint(1, type(uint256).max);
        vm.stopPrank();
    }

    function _approve(uint256 nonce, uint256 deadline) internal {
        IMD6900Frens.Quote memory q = IMD6900Frens.Quote("r", bytes32(0), "q", bytes32(0), bytes32(0), "a", block.timestamp + 600);
        vm.prank(keeper);
        frens.approveJob(id, nonce, deadline, q);
    }

    function _settle(uint256 nonce, uint256 deadline, uint256 amount, address to) internal {
        ISignatureTransfer.PermitTransferFrom memory permit =
            ISignatureTransfer.PermitTransferFrom(ISignatureTransfer.TokenPermissions(IMD, amount), nonce, deadline);
        bytes32 witness = keccak256(abi.encode(WITNESS_TYPEHASH, to, uint256(0)));
        vm.prank(X402_PROXY); // what the proxy does when IMD settles the payment
        ISignatureTransfer(PERMIT2).permitWitnessTransferFrom(
            permit, ISignatureTransfer.SignatureTransferDetails(to, amount), address(frens), witness, WITNESS_TYPE, ""
        );
    }

    function test_Permit2SettlesTheApprovedJob() public {
        uint256 deadline = block.timestamp + 600;
        _approve(7, deadline);
        _settle(7, deadline, 0.5e18, payTo);
        assertEq(IERC20(IMD).balanceOf(payTo), 0.5e18);
        assertEq(IERC20(IMD).balanceOf(address(frens)), 0.19e18, "only the job left; the floor part stays");
    }

    function test_Permit2RefusesAnotherAmount() public {
        uint256 deadline = block.timestamp + 600;
        _approve(7, deadline);
        vm.expectRevert();
        _settle(7, deadline, 0.69e18, payTo);
    }

    function test_Permit2RefusesAnotherPayee() public {
        uint256 deadline = block.timestamp + 600;
        _approve(7, deadline);
        vm.expectRevert();
        _settle(7, deadline, 0.5e18, makeAddr("thief"));
    }

    function test_Permit2RefusesAnUnapprovedJob() public {
        vm.expectRevert();
        _settle(7, block.timestamp + 600, 0.5e18, payTo);
    }

    function test_EachApprovalPaysOnce() public {
        uint256 deadline = block.timestamp + 600;
        _approve(7, deadline);
        _settle(7, deadline, 0.5e18, payTo);
        vm.expectRevert(); // the nonce is spent
        _settle(7, deadline, 0.5e18, payTo);
    }
}
