#!/usr/bin/env python3
"""The frens' mint price curve: what the n-th fren of 2222 costs, as a table the contract reads (SSTORE2).

    python3 script/frens/price/prices.py

An S-curve (logistic) from 0.69 $IMD toward a ceiling of 6.9: p(n) = 6.9 / (1 + 9 e^(-k n)). It grows exponentially at
first and flattens like a log; k is chosen so all 2222 frens together cost TOTAL $IMD (about 30 ETH at $IMD's price when
it was set: 1 $IMD = 0.004053 ETH on IMD's pool, 2026-10-05). The first fren costs exactly 0.69, the last 6.08.
Prices are kept in units of 0.0001 $IMD (1e14 wei), 3 bytes each, big-endian, fren 0 first: 6666 bytes. Writes
prices.bin and prices.json (the parameters and a few points).
"""
import json, math, os
HERE = os.path.dirname(os.path.abspath(__file__))
N, LO, HI, UNIT, TOTAL = 2222, 0.69, 6.9, 1e-4, 7380
A = HI / LO - 1
table = lambda k: [round(HI / (1 + A * math.exp(-k * n)) / UNIT) for n in range(N)]
lo, hi = 0.0, 2 * math.log(A) / (N - 1)  # the symmetric curve's k costs more than TOTAL; find the k that costs TOTAL
for _ in range(80):
    mid = (lo + hi) / 2
    lo, hi = (lo, mid) if sum(table(mid)) * UNIT > TOTAL else (mid, hi)
K = (lo + hi) / 2
units = table(K)
assert units[0] == 6900 and all(b >= a for a, b in zip(units, units[1:])) and units[-1] < 69000
open(os.path.join(HERE, "prices.bin"), "wb").write(b"".join(u.to_bytes(3, "big") for u in units))
total = sum(units) * UNIT
points = {str(n): round(units[n] * UNIT, 4) for n in [0, 250, 500, 1000, 1162, 1500, 2000, 2221]}
json.dump({"formula": "6.9 / (1 + 9 * exp(-k * n))", "k": K, "unitWei": "100000000000000", "frens": N, "total": round(total, 4),
           "ethAtSetting": round(total * 0.004053, 2), "points": points}, open(os.path.join(HERE, "prices.json"), "w"), indent=1)
print(f"k {K:.10f}, all 2222 frens {total:,.1f} $IMD (~{total * 0.004053:.1f} ETH at 0.004053)")
for k, v in points.items(): print(f"  fren {int(k) + 1:>4}: {v:7.4f} $IMD")
