# IMD6900 Frens: security review brief

A snapshot of the IMD6900 Frens contracts for an independent security review before the Ethereum mainnet launch.
It builds and tests offline: every library is vendored under `lib/` (only the files imported).

```
forge build --offline
forge test --offline                                   # 100 tests; the 5 mainnet-fork suites skip without an RPC
MAINNET_RPC_URL=https://… forge test                   # 130 tests, against live mainnet state
```

Any installed solc ≥ 0.8.26 compiles it (auto-detected). The deploy uses 0.8.30, via-IR, 200 runs, cancun.

## What it is

2222 on-chain NFTs ("frens"). Each mint request (1 to 69 frens) pays one paid job in the IMD agent swarm, in which
five agents choose the frens' traits layer by layer; the rest of the price backs a floor that any holder can sell into.

| Contract | Role |
|---|---|
| `src/frens/IMD6900Frens.sol` | The ERC-721 (ERC-721C, ERC-2981). Mint, reveal, the job payment (ERC-1271), the floor, recycle / buyTreasury. |
| `src/frens/FrenSwapper.sol` | Buys the floor: $IMD → IMD6900 on the IMD6900/$IMD v4 pool, fee ETH → $IMD (POOL4) → IMD6900. Prices IMD6900 for the mint (`floorRate`). |
| `src/frens/FrenMinter.sol` | Mint with ETH (exact-output $IMD on POOL4), quotes, `buyImd` for the owner's pre-opening mint. |
| `src/frens/FrenWorkerGate.sol` | The workers' window: after opening, the next 420 frens go to identity.md holders only, one per NFT. |
| `src/frens/FrenRenderer.sol` | On-chain SVG art (SSTORE2 layers), tokenURI / pendingURI. |
| `script/frens/DeployFrens.s.sol` | The deploy: art, price table, contracts (frens and swapper at fixed CREATE3 addresses via CreateX), wiring, trait rules, seal; `firstFrens` (owner pre-mint); `handover`. |
| `script/frens/FrensTimelockBatch.s.sol`, `proposals/frens-batch.sh` | The timelock batch already queued: launch-hook fee 10% → 6.9%, fee address → frens, frens as IMD6900 distributor, swapper fee-exempt on the pair pool. |
| `tools/fren-relayer.mjs`, `tools/fren-job.mjs` | Off-chain: posts the IMD job, reads the agents' output, signs the reveal voucher. Context for the relayer trust model. |

## How value moves

- **Mint** (`requestMint` / `requestMintFor`, or `FrenMinter.mintWithEth`): the price is `quote(count)` = the larger of
  the S-curve table (0.69 → 6.9 $IMD, `script/frens/price`) and `count × floor value / frens out` (the floor's
  IMD6900 counted at `FrenSwapper.floorRate()`, the lower of the pool's price and a slow average of the floor's own
  buys). 0.5 $IMD per request goes to `jobBudget`; the rest to `floorImd`, and the mint buys up to `maxImdPerBuy` of
  it into IMD6900 at once (one buy a block, each stopped at half the pair pool's fee of price movement).
- **Tier**: the minter's bag after paying ($IMD, IMD6900, identity.md NFTs), read only while v4's PoolManager is
  locked, sets how many frens one request may ask for (1/6/22/69) and which trait values the agents may give them.
- **Reveal**: frens mint unrevealed. The relayer signs an EIP-712 voucher naming one combo per fren; `reveal` checks
  every combo against the sealed trait rules (caps, min tiers, pair rules, uniqueness, pepes held for low tiers) and
  may run in parts. A job that doesn't land reveals nothing; anyone can pay another (`retryJob`).
- **Job payment**: `approveJob` (keeper) approves exactly one Permit2 witness transfer of 0.5 $IMD to IMD's payee
  through the x402 proxy, plus IMD's quote approval; the contract answers ERC-1271 only for those digests. A payment
  that lapsed untaken is reused.
- **Floor**: `recycle` sells a fren to the treasury for its share (reserve / out, floorImd / out); `buyTreasury` buys
  one back at twice that; fee ETH and royalties are bought into the reserve (`buyFloorWithEth`, `unwrapWeth`). Nothing
  else takes IMD6900 out.
- **Workers' window**: once the mint opens, `FrenWorkerGate.spend` requires a credit per fren for the next 420;
  `claim(ids, to)` turns identity.md NFTs into credits (the IMD6900 strategy's seat operator claims the strategy's own).
  The gate's owner (the deployer, no timelock) can end the window early. Before opening, only the frens' owner mints.

## Roles and trust

- **Owner**: the deployer until `handover`, then the Ethereum timelock (48h). Settings, modules (swapper, gate),
  royalty, tiers. The trait rules are sealed at deploy; min tiers can only go down afterwards.
- **Keeper**: approves job payments. **Relayer**: signs vouchers; it can only choose among combos the contract accepts.
- **Gate owner**: the deployer; can only widen who may mint (`openPublic`).
- The swapper and the gate are callable only by the frens contract where it matters.

## What we'd like checked

1. The floor's accounting: `reserve` and `floorImd` always backed by balances; recycle / buyTreasury / mint / floor buys
   keep each fren's share fair; nothing lets a fren be sold to the floor for more than its mint added.
2. The mint price never below the floor value, including through `floorRate` and pool price movement; the floor buys'
   price limits and their cost to anyone moving the pools around them.
3. The job payment: only the approved Permit2 / quote digests validate; allowance and `jobBudget` bookkeeping across
   lapsed payments, retries and full reveals.
4. Reveal: voucher replay or reuse across requests and parts; trait caps, tiers, pair rules, pepes held for low tiers.
5. Tiers: any way to reach a higher tier without holding the bag (borrowed balances, the treasury, other contracts).
6. The workers' window: credits, double use of an NFT, the boundary at 420, the owner's pre-opening mint.
7. FrenMinter / FrenSwapper: v4 unlock callbacks, deltas, refunds, leftovers; ETH and token handling.
8. ERC-721C validation and its exemptions; ERC-2981; the renderer's output for every valid combo.
9. The deploy script and the queued timelock batch (fixed CREATE3 addresses named before deployment).

## Already fixed in this snapshot (from our own review)

- `FrenSwapper`'s average now starts at the pool's price at deployment (a one-block move before the first floor buy
  used to set it outright). `test_OneBlockCannotSetTheAverage`.
- Treasury count is `balanceOf(this)`: a fren transferred in directly no longer skews the floor's count or strands a
  recycled fren. `test_FrenSentStraightToTheTreasuryCounts`.
- No mint to the frens contract itself (its own bag would set the tier). `test_NoMintIntoTheTreasury`.
- Fee-ETH floor buys have their own one-a-block slot. `test_DustEthBuyCannotTakeTheMintsTurn`.

## Accepted by design

- The owner (timelock) can replace the swapper and raise `maxImdPerBuy`, so a malicious swapper could take the waiting
  `floorImd`; the reserve (IMD6900) cannot be moved by any owner call. 48h notice lets holders exit at the floor first.
- The owner can redirect future job payments (`imdPayTo`); at most `jobBudget`.
- If a request is fully revealed while an approved payment is still untaken, that 0.5 $IMD stays idle.
- `floorRate` lags the pool by design (1/64 per buy-block) and only ever counts IMD6900 at its dearer reading.

## Mainnet addresses

| | |
|---|---|
| $IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| IMD6900 (strategy, the token) | `0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F` |
| identity.md | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` |
| v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Pair pool hook (IMD6900/$IMD) | `0x667f4621030aCfAfb1bD0B64d33610A8567f2A44` |
| POOL4 hook (ETH/$IMD) | `0xc6C965Bd164c483e87d0B550671798e9A3602840` |
| Launch hook (IMD6900/ETH) | `0xA16026A28aA581AA96713d20C608Da7F8db86444` |
| Timelock (48h) | `0xBd3ed9F4AbD9946cA6F59C8F13A3EbebDE1EA29D` |
| IMD6900Frens (fixed, CREATE3) | `0x69004fEd3d8a34FFA952d15A128f74D8340fa79d` |
| FrenSwapper (fixed, CREATE3) | `0x6900D4a8a26C9B24978b5fC1341d8c811B374624` |
| Permit2 / x402 proxy | `0x000000000022D473030F116dDEE9F6B43aC78BA3` / `0x402085c248EeA27D92E8b30b2C58ed07f9E20001` |

Vendored libraries keep their own licenses (forge-std MIT/Apache-2.0, OpenZeppelin MIT, Solady MIT, Uniswap v4-core
per file: MIT, one BUSL-1.1 file).
