---
name: fren-review-report
description: The report writer of a Fren Review deep review of the IMD6900 Frens contracts. Merge the four hunters' work, re-run every repro test, merge by root cause, challenge each finding, write one report.
---

# 🐸 Fren Review REPORT: IMD6900 Frens

Read `AUDIT.md` and `skills/hunt/SKILL.md` (clusters, invariants, harnesses, proof standard, severity). You get
the four hunters' merged trees: `review/hunt_a.md` … `review/hunt_d.md` and their tests under `test/fren-review/`.

## Rules

Never touch a live chain. Write only `review/REPORT.md`, `test/fren-review/report/` (contract names start with
`Report`), `artifacts/fren-review-report.md`, `artifacts/fren-review-findings.json`. Keep every hunter's tests;
`forge build` and `forge test` must pass on the merged tree.

## Procedure

1. **Build and run everything.** `forge build`, `forge test`, each hunter's directory with `-vvv` (fork tests with
   `MAINNET_RPC_URL` when one is available). A hunter's test that fails or skipped proves nothing.
2. **Inventory** every finding, lead and cluster verdict, with who wrote it.
3. **Reproduce** each finding: read its test against the proof standard; the numbers you see win over the prose. If
   the test is weak but the bug looks real, write a proper one in `test/fren-review/report/`.
4. **Merge by root cause**: one root cause is one finding, every hunter who found it credited.
5. **Try to kill each one** with the hunt skill's checklist. What falls becomes a refuted claim with the guard at
   `file:line`, or a lead if merely unproven.
6. **Set severity** from what the test shows, one sentence why. Evidence, never majority.
7. **Write it up** in the structure below.

If the verifier reopens your step, reproduce each of its findings; correct the report where they hold, say why
where they don't, and answer every one in `.imd-responses.json`.

## What you leave

`review/REPORT.md`, and the same text in `artifacts/fren-review-report.md`:

```markdown
# Fren Review deep review: IMD6900 Frens, <baseCommit short sha>

## Summary
<3–6 lines: what was tested, findings by severity, the single most important thing>

## Coverage
| cluster | verdict | hunters (solid/suspect/defect) | deepest attempt |
<one row per cluster: mint, reveal, job, floor, swapper, minter, gate, nft, deploy>

## Findings
### F-1 <severity>: <one-line title>
- **Where:** `path:line` (`Contract.function`), the root cause
- **Found by:** hunt_a, hunt_c
- **Invariant:** <F1–F10 and the property it breaks>
- **Sequence:** <actor, capital, preconditions, steps>
- **Impact:** <numbers from the test>
- **Repro test:** `test/fren-review/<dir>/<File>.t.sol::<test>`: `[PASS] …` (your run), control `<test>`
- **Why this severity:** <one sentence>
- **Fix direction:** <root cause, not symptom>

## Refuted claims
- <claim> (hunt_b): refuted by the guard at `file:line`: <why>

## Leads for the next job
- <cluster> | `path:line` | <the suspicion, and the test that would settle it>
```

`artifacts/fren-review-findings.json`:

```json
{"commit": "<baseCommit>",
 "coverage": {"floor": {"verdict": "solid", "examined": 14}},
 "findings": [{"id": "F-1", "severity": "medium", "title": "...", "path": "src/frens/IMD6900Frens.sol", "line": 123,
               "invariant": "F2", "foundBy": ["hunt_a"], "test": "test/fren-review/hunt_a/HuntAX.t.sol::test_HuntA_X",
               "impact": "...", "fix": "..."}],
 "refuted": [{"claim": "...", "by": "hunt_b", "path": "...", "line": 0, "guard": "file:line", "why": "..."}],
 "leads": [{"cluster": "swapper", "path": "...", "line": 0, "text": "..."}]}
```

Your final message starts with:

```
FREN-REVIEW REPORT v1
findings: critical 0 | high 0 | medium 1 | low 2 | info 0
refuted: 3
leads: 4
coverage: mint solid, reveal solid, job solid, floor defect, swapper solid, minter solid, gate solid, nft solid, deploy solid
```
