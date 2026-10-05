#!/usr/bin/env python3
"""The frens' mint price curve: what the n-th fren of 2222 costs, as a table the contract reads (SSTORE2).

    python3 script/frens/price/prices.py

Two parts (decided 2026-10-05):
  1. The cheap start, frens 1-560: the strategy's first 140 (paid from IMD6900's NFT pot before the opening) and the
     workers' window's 420 (identity.md holders, one per NFT). A slow exponential from 0.69 to 0.95 $IMD.
  2. Then steeper: a logistic that starts where the window ends, grows exponentially, and plateaus. It reaches 95% of
     its plateau REACH frens after the window; the plateau is chosen so all 2222 frens together cost TOTAL_ETH at
     $IMD's price when it was set (IMD_PER_ETH: IMD's ETH/$IMD pool, POOL4).
Prices are kept in units of 0.0001 $IMD (1e14 wei), 3 bytes each, big-endian, fren 0 first: 6666 bytes. Writes
prices.bin and prices.json (the parameters and a few points).
"""
import json, math, os
HERE = os.path.dirname(os.path.abspath(__file__))
N, UNIT = 2222, 1e-4
LO = 0.69  # fren 1
STRATEGY, WORKERS = 140, 420  # the cheap start: the strategy's first frens, then the workers' window
NW = STRATEGY + WORKERS  # the window ends with fren NW (index NW - 1)
TOP_W = 0.95  # fren NW's price: the last of the window
REACH = 400  # frens after the window to reach 95% of the plateau
TOTAL_ETH, IMD_PER_ETH = 22.22, 244.03  # POOL4 spot, 2026-10-05
TOTAL = TOTAL_ETH * IMD_PER_ETH

a = math.log(TOP_W / LO) / (NW - 1)
start = [LO * math.exp(a * n) for n in range(NW)]


def table(plateau):
    c = plateau / TOP_W - 1  # the logistic through TOP_W at the window's last fren
    k = math.log(c / (1 / 0.95 - 1)) / REACH  # ...and through 95% of the plateau REACH frens later
    rise = [plateau / (1 + c * math.exp(-k * (n - NW + 1))) for n in range(NW, N)]
    return [round(p / UNIT) for p in start + rise], k


lo, hi = 2 * TOP_W, 20.0  # above twice the window's top the logistic starts in its exponential half
for _ in range(80):
    mid = (lo + hi) / 2
    lo, hi = (lo, mid) if sum(table(mid)[0]) * UNIT > TOTAL else (mid, hi)
PLATEAU = (lo + hi) / 2
units, K = table(PLATEAU)
assert units[0] == 6900 and units[NW - 1] == round(TOP_W / UNIT) and all(b >= a for a, b in zip(units, units[1:]))
open(os.path.join(HERE, "prices.bin"), "wb").write(b"".join(u.to_bytes(3, "big") for u in units))
total = sum(units) * UNIT
points = {str(n): round(units[n] * UNIT, 4) for n in [0, STRATEGY - 1, NW - 1, 650, 750, 850, 960, 1200, 1500, 2221]}
json.dump({
    "formula": f"frens 1-{NW}: {LO} * ({TOP_W}/{LO})^(n/{NW - 1}); then plateau / (1 + c e^(-k (n - {NW - 1}))), c = plateau/{TOP_W} - 1",
    "strategy": STRATEGY, "workers": WORKERS, "windowTop": TOP_W, "plateau": round(PLATEAU, 6), "k": K, "reach": REACH,
    "unitWei": "100000000000000", "frens": N, "total": round(total, 4), "imdPerEthAtSetting": IMD_PER_ETH,
    "ethAtSetting": round(total / IMD_PER_ETH, 2), "points": points,
}, open(os.path.join(HERE, "prices.json"), "w"), indent=1)
print(f"plateau {PLATEAU:.4f}, k {K:.6f}; all 2222 frens {total:,.1f} $IMD (~{total / IMD_PER_ETH:.2f} ETH at {IMD_PER_ETH} $IMD/ETH)")
print(f"  strategy 1-{STRATEGY}: {sum(units[:STRATEGY]) * UNIT:.1f} $IMD; workers {STRATEGY + 1}-{NW}: {sum(units[STRATEGY:NW]) * UNIT:.1f} $IMD")
for k, v in points.items(): print(f"  fren {int(k) + 1:>4}: {v:7.4f} $IMD")
