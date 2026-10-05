// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

interface ILaunchHook {
    function defaultFee() external view returns (uint128);
    function feeAddress() external view returns (address);
    function lowerFee(uint128 newFee) external;
    function updateFeeAddress(address feeAddress) external;
}

interface IPairHook {
    function setFeeExempt(address caller, bool exempt) external;
    function feeExempt(address) external view returns (bool);
}

interface IStrategy {
    function setDistributor(address distributor, bool status) external;
    function isDistributor(address) external view returns (bool);
}

interface ITimelock {
    function hashOperationBatch(address[] calldata, uint256[] calldata, bytes[] calldata, bytes32, bytes32)
        external
        pure
        returns (bytes32);
}

/// @notice The Ethereum timelock batch for the frens, once IMD6900Frens is deployed (decided 2026-09-29):
///  1. the launch hook's trading fee 10% -> 6.9% (it can never go back up);
///  2. the hook's fee-address slice (the deployer's today) goes to the frens contract, which buys it into the floor;
///  3. the frens contract becomes an IMD6900 distributor: IMD6900 moves only through its pools or to and from
///     distributors, so without this no one can sell a fren to the floor (recycle pays IMD6900) or buy one back;
///  4. the frens' swapper trades on the IMD6900/$IMD pool without its fee: the floor's own buys keep the 6.9%. Only the
///     frens contract can call the swapper, and only with the floor's own money, so nobody else's trade goes fee-free.
///  This only simulates the batch as the timelock on a fork and prints what to queue; it sends nothing.
///
///   forge script script/frens/FrensTimelockBatch.s.sol --sig "run(address)" <frens> --fork-url $MAINNET_RPC_URL
contract FrensTimelockBatch is Script {
    address public constant HOOK = 0xA16026A28aA581AA96713d20C608Da7F8db86444;
    address public constant TIMELOCK = 0xBd3ed9F4AbD9946cA6F59C8F13A3EbebDE1EA29D;
    address public constant IMD6900 = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F; // the strategy: owner is TIMELOCK
    address public constant PAIR_HOOK = 0x667f4621030aCfAfb1bD0B64d33610A8567f2A44; // owner is TIMELOCK
    address public constant SWAPPER = 0x6900D4a8a26C9B24978b5fC1341d8c811B374624; // CREATE3, see DeployFrens
    uint128 public constant FEE = 690;
    bytes32 public constant SALT = keccak256("imd6900-frens-batch-1");

    function batch(address frens) public pure returns (address[] memory targets, uint256[] memory values, bytes[] memory datas) {
        targets = new address[](4);
        values = new uint256[](4);
        datas = new bytes[](4);
        (targets[0], targets[1], targets[2], targets[3]) = (HOOK, HOOK, IMD6900, PAIR_HOOK);
        datas[0] = abi.encodeCall(ILaunchHook.lowerFee, (FEE));
        datas[1] = abi.encodeCall(ILaunchHook.updateFeeAddress, (frens));
        datas[2] = abi.encodeCall(IStrategy.setDistributor, (frens, true));
        datas[3] = abi.encodeCall(IPairHook.setFeeExempt, (SWAPPER, true));
    }

    function run(address frens) external {
        require(frens.code.length > 0, "frens is not deployed here");
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) = batch(frens);
        console2.log("fee before", ILaunchHook(HOOK).defaultFee(), "fee address", ILaunchHook(HOOK).feeAddress());
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(TIMELOCK);
            (bool ok, bytes memory err) = targets[i].call{value: values[i]}(datas[i]);
            require(ok, string(err));
        }
        require(ILaunchHook(HOOK).defaultFee() == FEE && ILaunchHook(HOOK).feeAddress() == frens, "the batch didn't take");
        require(IStrategy(IMD6900).isDistributor(frens), "frens isn't a distributor");
        require(IPairHook(PAIR_HOOK).feeExempt(SWAPPER), "the swapper isn't fee-exempt");
        console2.log("fee after ", ILaunchHook(HOOK).defaultFee(), "fee address", ILaunchHook(HOOK).feeAddress());
        console2.log("operation id");
        console2.logBytes32(ITimelock(TIMELOCK).hashOperationBatch(targets, values, datas, bytes32(0), SALT));
        console2.log("queue (deployer = proposer), executable 48h later with executeBatch and the same arguments:");
        console2.log("cast send <timelock> 'scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)'");
        console2.log("  targets", targets[0], targets[1], targets[2]);
        console2.log("          ", targets[3]);
        console2.log("  datas");
        console2.logBytes(datas[0]);
        console2.logBytes(datas[1]);
        console2.logBytes(datas[2]);
        console2.logBytes(datas[3]);
        console2.log("  predecessor 0x0, salt keccak256('imd6900-frens-batch-1'), delay 172800");
    }
}
