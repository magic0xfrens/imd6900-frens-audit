---
name: fren-review-hunt
description: One of four independent hunters in a Fren Review deep review of the IMD6900 Frens contracts. Review from your angle, prove every finding with a local Foundry test, report in the FREN-REVIEW v1 format.
---

# 🐸 Fren Review HUNT: IMD6900 Frens

A defensive security review commissioned by the project's own team, of its own open-source code, before mainnet.
Read `AUDIT.md` first: what the contracts do, how value moves, the roles, what we want checked, what is already fixed
and what is accepted by design.

## 📜 Rules

1. **Never touch a live chain.** No transactions, no private keys. Read-only RPC at most (fork tests).
2. **Write only your step's paths:** `test/fren-review/hunt_<x>/` and `review/hunt_<x>.md`. `test/scratch/` is for
   throwaway work and is deleted before you submit. Every contract name starts with `Hunt<X>` (`HuntA…`).
3. **Proof over prose.** A claim you did not run is a `lead`, not a finding.
4. **Never bless a bug.** A repro test asserts the harm (it passes *because* the bug is there).
5. `forge build` and `forge test` must pass with everything you leave.

## 🧩 The job

| step | skill | writes |
|---|---|---|
| `hunt_a` … `hunt_d` (in parallel, blind to each other) | this file | `test/fren-review/hunt_<x>/`, `review/hunt_<x>.md` |
| `report` | `skills/report/SKILL.md` | `review/REPORT.md`, `test/fren-review/report/`, two artifacts |
| `verify` | `skills/verify/SKILL.md` | nothing tracked; findings only |

## 🗺️ Clusters

| cluster | code |
|---|---|
| mint | `IMD6900Frens.requestMint*`, `quote`, `_prices`, tiers (`_lockedTierOf`, `_tier`, `maxMint`), pepes held for low tiers |
| reveal | `reveal`, `voucherDigest`, `check`, `_tierNeeded`, trait rules, pair rules, `revealedHashOf` |
| job | `approveJob`, `retryJob`, `_spent`, `_unapprove`, `isValidSignature`, `_permit2Digest`, `_quoteApprovalDigest`, `jobBudget` |
| floor | `reserve`, `floorImd`, `_buyFloor`, `buyFloor`, `buyFloorWithEth`, `unwrapWeth`, `recycle`, `buyTreasury`, `floorPerFren`, `inTreasury` |
| swapper | `FrenSwapper` (v4 unlock, price limits, `spotRate`, `floorRate`, `_average`) |
| minter | `FrenMinter` (`mintWithEth`, `buyImd`, quotes, `maxRequest`) |
| gate | `FrenWorkerGate` and the frens' `workerGate` hook, the owner's pre-opening mint |
| nft | ERC-721C validation and its exemptions, ERC-2981, `FrenRenderer` / `FrenArt` |
| deploy | `script/frens/DeployFrens.s.sol`, `FrensTimelockBatch.s.sol`, `proposals/frens-batch.sh` |

## ⚖️ Invariants

- **F1** `IMD6900.balanceOf(frens) >= reserve`; `IMD.balanceOf(frens) >= floorImd + jobBudget` (plus approved, untaken job payments).
- **F2** Selling a fren to the floor (`recycle`) never pays more than its fair share: `reserve / out`, `floorImd / out`, `out = totalMinted - inTreasury()`.
- **F3** A mint never costs less than the floor value it joins (`quote`), so mint-then-recycle never nets a gain.
- **F4** Only the frens contract's own floor money is ever swapped; the swapper and minter hold nothing between calls.
- **F5** The contract's ERC-1271 approves only digests `approveJob` approved; each request's paid jobs are used at most once.
- **F6** Every revealed combo is unique, within its trait caps, allowed for the request's tier and pair rules; low-tier requests always have pepes left.
- **F7** A request's tier is the minter's own bag, never borrowed within the transaction, never the treasury's.
- **F8** In the workers' window each identity.md NFT gives at most one fren; outside the window (after 420 or `openPublic`) the gate never blocks.
- **F9** Trades between holders go past the transfer validator; only mints, burns and the floor's own moves skip it.
- **F10** The deploy lands the frens and the swapper at the addresses the queued timelock batch names, wired and sealed.

## 🔭 Harnesses

- **Unit** (`test/frens/IMD6900Frens.t.sol`, `FrenWorkerGate.t.sol`): the real `IMD6900Frens`/`FrenWorkerGate` with
  mock tokens, a mock swapper and a mock Permit2. Import its mocks and setup; `forge test --offline` runs it.
- **Fork** (`test/frens/*.fork.t.sol`): the real contracts against live mainnet pools, via `DeployFrens.deploy`.
  They need `MAINNET_RPC_URL` and skip without it. A fork repro that skipped proves nothing: run it with an RPC and
  paste the `[PASS]` line, or report it as a lead.

## 🧾 Proof standard

- **Actors**: plain EOAs and contracts you deploy. Prank as owner, keeper, relayer or gate owner only to set up
  what the deploy and an honest operator would do (e.g. the relayer signs the voucher the agents' job produced),
  never to make a role misbehave, unless the finding is about a guard on that role.
- **State**: no `vm.store`/`vm.etch`/`deal` on the frens contracts beyond what the existing tests' setups do; reach
  preconditions through public calls. `vm.warp`/`vm.roll` are fine.
- **Damage in numbers** (balances before/after, the caller's net after fees, the invariant broken), and **a
  control**: the same sequence without the triggering step behaves correctly.
- **Kill it first**: does it need a trusted role to misbehave? Is every precondition reachable at the deploy's real
  parameters? Is it in AUDIT.md's fixed or accepted lists? Does a guard elsewhere stop it? What does the caller pay?

## 📤 Reporting

Leave three things that agree: `review/hunt_<x>.md`, `.imd-findings.json` at the repo root, and your final message.
Both the write-up and the final message start with this block (final message under ~3,500 characters):

```
FREN-REVIEW v1
focus: frens / <your letter>
floor: defect | 14 | recycle after a direct transfer in: share recomputed (F2)
mint: solid | 9 | quote at out=1 with a moved pool (F3)
lead: swapper | src/frens/FrenSwapper.sol:123 | <the suspicion>; prove it by <the test that would settle it>
```

One line per cluster you examined: name, `solid` / `suspect` / `defect`, entry points examined, your deepest
attempt and the invariant. Up to five `lead:` lines. Findings in `.imd-findings.json`:

```json
{"findings": [{"severity": "medium", "title": "...", "path": "src/frens/IMD6900Frens.sol", "line": 123,
  "description": "Root cause ... Caller and capital ... Preconditions ... Impact in numbers ... Invariant ... Fix direction ...",
  "reproduction": "exact steps; the repro test test/fren-review/hunt_a/HuntAX.t.sol::test_HuntA_X, the command, the [PASS] line"}]}
```

Severity: **critical** an outsider cheaply takes or permanently locks funds or bricks a core flow; **high** loss
under realistic conditions or long-lived denial of mint, reveal or recycle; **medium** bounded loss, costly
griefing, accounting errors without direct loss; **low** minor edge cases; **info** no security impact.
Finding nothing is a valid result when your coverage shows you examined everything from your angle.
