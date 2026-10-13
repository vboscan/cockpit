#!/usr/bin/env bash
# Where the budget goes: weighted tokens per spec × stage from the ledger.
#
# usage: scripts/usage-report.sh [--spec NN] [--slice S] [--json]
#
# Weighted = input×1 + cache_read×0.1 + cache_write×2 + output×5 (README "Hot
# path"). Also prints the implementer's fixed context per turn — the hot-path
# lever — and gate share of the iteration. cost_usd is API list price: on a
# subscription it is a relative weight between stages, not a bill.
set -uo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usage-lib.sh"
spec=""; slice=""; as_json=0
while [ $# -gt 0 ]; do case "$1" in --spec) spec="${2-}"; shift 2;; --slice) slice="${2-}"; shift 2;; --json) as_json=1; shift;; *) echo "usage: $(basename "$0") [--spec NN] [--slice S] [--json]" >&2; exit 2;; esac; done
[[ -f "${RALPH_USAGE_LEDGER}" ]] || { echo "usage-report: no ledger at ${RALPH_USAGE_LEDGER}" >&2; exit 1; }
python3 - "${RALPH_USAGE_LEDGER}" "${spec}" "${slice}" "${as_json}" <<'PY'
import json, sys
from collections import defaultdict
path, spec, slice_, as_json = sys.argv[1:5]
rows=[]
for line in open(path):
    try: d=json.loads(line)
    except ValueError: continue
    if spec and d.get("spec")!=spec: continue
    if slice_ and d.get("slice")!=slice_: continue
    rows.append(d)
agg=defaultdict(lambda: {"rows":0,"input":0,"output":0,"cache_read":0,"cache_write":0,"cost_usd":0.0,"weighted":0,"turns":0,"fixed":[]})
for d in rows:
    k=(d.get("spec","?"), d.get("stage","?")); a=agg[k]
    a["rows"]+=1
    for f in ("input","output","cache_read","cache_write","weighted"): a[f]+=int(d.get(f) or 0)
    a["cost_usd"]+=float(d.get("cost_usd") or 0); a["turns"]+=int(d.get("num_turns") or 0)
    if d.get("fixed_context_per_turn"): a["fixed"].append(int(d["fixed_context_per_turn"]))
if int(as_json):
    print(json.dumps({f"{k[0]}/{k[1]}": {**v, "fixed": (sum(v["fixed"])//len(v["fixed"]) if v["fixed"] else None)} for k,v in sorted(agg.items())}, indent=1)); sys.exit()
tot=sum(v["weighted"] for v in agg.values()) or 1
print(f"{'spec':<6}{'stage':<16}{'rows':>5}{'turns':>7}{'input':>9}{'cache_rd':>11}{'cache_wr':>10}{'output':>9}{'weighted':>11}{'share':>7}{'cost$':>8}{'ctx/turn':>10}")
for (s,st),v in sorted(agg.items()):
    fixed=(sum(v["fixed"])//len(v["fixed"])) if v["fixed"] else ""
    print(f"{s:<6}{st:<16}{v['rows']:>5}{v['turns']:>7}{v['input']:>9}{v['cache_read']:>11}{v['cache_write']:>10}{v['output']:>9}{v['weighted']:>11}{100*v['weighted']/tot:>6.0f}%{v['cost_usd']:>8.2f}{fixed:>10}")
gates=sum(v["weighted"] for (s,st),v in agg.items() if st in ("security-review","code-review","spec-review","confirm","plan-review","adversary"))
print(f"\nweighted total {tot}; gates+reviews {100*gates/tot:.0f}% of it; ledger {path}")
PY
