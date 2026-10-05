#!/usr/bin/env bash
# Ethereum timelock batch for the IMD6900 frens (queued before the frens are deployed: their address is fixed ahead by
# CreateX's CREATE3, from the deployer and a salt only it can use, whatever the final code is):
#   1  the launch hook's trading fee 10% -> 6.9% (it can never go back up)
#   2  the hook's fee-address slice (the deployer's today) -> the frens contract, which buys it into the floor
#   3  the frens contract becomes an IMD6900 distributor: IMD6900 moves only through its pools or to and from
#      distributors, so selling a fren to the floor (recycle pays IMD6900) needs this
#   4  the frens' swapper trades on our IMD6900/$IMD pool without its fee: the floor's buys keep the 6.9%. Only the frens
#      contract can call the swapper, with the floor's own money: nobody else's trade goes fee-free
#
#   proposals/frens-batch.sh schedule   queue it (the deployer is a proposer); executable 48h later
#   proposals/frens-batch.sh status     pending / ready / done
#   proposals/frens-batch.sh execute    run it once ready (the deployer is an executor); deploy the frens first
#
# The frens deploy (script/frens/DeployFrens.s.sol) puts IMD6900Frens at FRENS with CreateX.deployCreate3(SALT_CREATE3).
# Before it exists, the hook's fee ETH just waits at that address and the contract keeps it when it's deployed there.
set -euo pipefail
RPC="${RPC:-https://rpc.mevblocker.io}"
SIGN=(--account "${ACCOUNT:-imdstr-deployer}")
TL=0xBd3ed9F4AbD9946cA6F59C8F13A3EbebDE1EA29D
HOOK=0xA16026A28aA581AA96713d20C608Da7F8db86444
IMD6900=0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F
FRENS=0x69004fEd3d8a34FFA952d15A128f74D8340fa79d # CreateX CREATE3 for the deployer 0x35dA…a059 and SALT_CREATE3 (mined: 0x6900…)
SALT_CREATE3=0x35da9c0303507ddf708e87f2568eddf12c47a059006672656e7300000004b760
PAIR_HOOK=0x667f4621030aCfAfb1bD0B64d33610A8567f2A44
SWAPPER=0x6900D4a8a26C9B24978b5fC1341d8c811B374624 # CREATE3, salt 0x35da…a05900737761707200000000e416
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
SALT=$(cast keccak "imd6900-frens-batch-1")
D1=$(cast calldata "lowerFee(uint128)" 690)
D2=$(cast calldata "updateFeeAddress(address)" $FRENS)
D3=$(cast calldata "setDistributor(address,bool)" $FRENS true)
D4=$(cast calldata "setFeeExempt(address,bool)" $SWAPPER true)
TARGETS="[$HOOK,$HOOK,$IMD6900,$PAIR_HOOK]"
VALUES="[0,0,0,0]"
DATAS="[$D1,$D2,$D3,$D4]"
ID=$(cast call $TL 'hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)' "$TARGETS" "$VALUES" "$DATAS" $ZERO $SALT --rpc-url "$RPC")

case "${1:-status}" in
  schedule)
    cast send $TL 'scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)' "$TARGETS" "$VALUES" "$DATAS" $ZERO $SALT 172800 "${SIGN[@]}" --rpc-url "$RPC"
    echo "queued: operation $ID, ready $(date -u -r $(( $(date +%s) + 172800 )) '+%a %d %b %H:%M UTC')"
    ;;
  execute)
    [ "$(cast code $FRENS --rpc-url "$RPC")" != "0x" ] && [ "$(cast code $SWAPPER --rpc-url "$RPC")" != "0x" ] || { echo "deploy the frens first ($FRENS, swapper $SWAPPER)"; exit 1; }
    # the code there is ours, wired to each other and sealed, before the timelock hands it the fees and IMD6900
    lc() { tr '[:upper:]' '[:lower:]'; }
    [ "$(cast call $FRENS 'swapper()(address)' --rpc-url "$RPC" | lc)" = "$(echo $SWAPPER | lc)" ] \
      && [ "$(cast call $SWAPPER 'frens()(address)' --rpc-url "$RPC" | lc)" = "$(echo $FRENS | lc)" ] \
      && [ "$(cast call $FRENS 'traitsSealed()(bool)' --rpc-url "$RPC")" = true ] \
      && [ "$(cast call $FRENS 'imd6900()(address)' --rpc-url "$RPC" | lc)" = "$(echo $IMD6900 | lc)" ] \
      || { echo "the contracts at $FRENS / $SWAPPER aren't the frens and their swapper, wired and sealed: not executing"; exit 1; }
    case "$(cast call $FRENS 'governor()(address)' --rpc-url "$RPC" | lc)" in
      0x35da9c0303507ddf708e87f2568eddf12c47a059|"$(echo $TL | lc)") ;;
      *) echo "the frens' governor is neither the deployer nor the timelock: not executing"; exit 1 ;;
    esac
    cast send $TL 'executeBatch(address[],uint256[],bytes[],bytes32,bytes32)' "$TARGETS" "$VALUES" "$DATAS" $ZERO $SALT "${SIGN[@]}" --rpc-url "$RPC"
    ;;
  status)
    t=$(cast call $TL 'getTimestamp(bytes32)(uint256)' $ID --rpc-url "$RPC" | awk '{print $1}')
    if [ "$t" = "0" ]; then echo "operation $ID: not queued"
    elif [ "$t" = "1" ]; then echo "operation $ID: done"
    else echo "operation $ID: queued, ready $(date -u -r "$t" '+%a %d %b %H:%M UTC') ($( [ "$(cast call $TL 'isOperationReady(bytes32)(bool)' $ID --rpc-url "$RPC")" = true ] && echo ready now || echo waiting))"; fi
    echo "hook fee $(cast call $HOOK 'defaultFee()(uint128)' --rpc-url "$RPC"), fee address $(cast call $HOOK 'feeAddress()(address)' --rpc-url "$RPC"), frens distributor $(cast call $IMD6900 'isDistributor(address)(bool)' $FRENS --rpc-url "$RPC"), swapper fee-exempt $(cast call $PAIR_HOOK 'feeExempt(address)(bool)' $SWAPPER --rpc-url "$RPC")"
    ;;
  *) echo "usage: proposals/frens-batch.sh schedule | status | execute"; exit 1 ;;
esac
