---
name: fren-review-verify
description: The verifier of a Fren Review deep review of the IMD6900 Frens contracts. Re-run the report's tests, try to overturn every finding and refutation, then look for what the four hunters missed.
---

# 🐸 Fren Review VERIFY: IMD6900 Frens

Read `AUDIT.md` and `skills/hunt/SKILL.md` (clusters, invariants, harnesses, proof standard, severity), then
`review/REPORT.md`. You change **no tracked file**: scratch repro tests live only under `test/scratch/`. Never touch a
live chain.

## Procedure

1. **Rebuild and re-run.** `forge build`, `forge test`, and every repro test the report cites with `-vvv` (fork tests
   with `MAINNET_RPC_URL` when available). An assertion that never ran proves nothing.
2. **Every finding.** Restate it as a falsifiable property (invariant, actor, gain). Check its test against the proof
   standard (no role made to misbehave, no storage writes, damage in numbers, a real control). Push it to its true
   worst case; the severity follows what you show, up or down.
3. **Every refuted claim.** Try the sequence against the cited guard from another direction (the ETH path instead
   of $IMD, a request revealed in parts, the treasury, the workers' window, a moved pool). A refutation that falls is
   a finding.
4. **What they missed.** Start from the report's weakest coverage (`suspect` clusters, few hunters, the leads) and
   AUDIT.md's "What we'd like checked". Prove every candidate in `test/scratch/`.

## Your findings and final message

`.imd-findings.json` at the repository root:
- a **new** finding or an **overturned refutation**: `path`/`line` at the root cause, the true severity, and a
  reproduction that ran (the test source, the command, the `[PASS]` line);
- an **overturned finding** or a **wrong severity**: `path` `review/REPORT.md`, `line` of the report's entry, severity
  `low`, title starting `Report error:`, and the guard or numbers that settle it.

```json
{"findings": [{"severity": "medium", "title": "...", "path": "src/frens/FrenSwapper.sol", "line": 123,
  "description": "Root cause ... Invariant ... Impact in numbers ... Not in the report because ...",
  "reproduction": "exact inputs, expected vs actual, the test source, command, [PASS] line"}]}
```

Your final message starts with this block, one line per report finding and refuted claim:

```
FREN-REVIEW VERIFY v1
upheld: F-1 | src/frens/IMD6900Frens.sol:123 | medium | test_HuntA_X [PASS]
overturned: F-2 | src/frens/FrenMinter.sol:45 | low -> none | guard at src/frens/FrenMinter.sol:40
severity: F-3 | src/frens/FrenSwapper.sol:77 | low -> medium | <one line>
refutation-upheld: src/frens/IMD6900Frens.sol:88 | guard at src/frens/IMD6900Frens.sol:80
refutation-overturned: src/frens/IMD6900Frens.sol:91 | high | see .imd-findings.json
new: 1
hunted: floor, swapper, gate
```
