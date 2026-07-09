#!/usr/bin/env bash
# Refreshes the market data embedded in index.html:
#   - Zillow ZORI (rent index) + ZHVI (home value index), Seattle + Bellevue
#   - FRED 30-year mortgage rate (monthly average of the weekly series)
#   - FRED/Census metro population (Seattle-Tacoma-Bellevue MSA, annual)
# The Zillow source CSVs are too large to fetch in the browser (~5MB / ~90MB),
# so the series are baked in as a small constant.
# Run weekly by .github/workflows/refresh-sip.yml; Zillow updates monthly.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$SCRIPT_DIR/index.html"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ZORI_URL="https://files.zillowstatic.com/research/public_csvs/zori/City_zori_uc_sfrcondomfr_sm_month.csv"
ZHVI_URL="https://files.zillowstatic.com/research/public_csvs/zhvi/City_zhvi_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv"
MORTGAGE_URL="https://fred.stlouisfed.org/graph/fredgraph.csv?id=MORTGAGE30US"
POP_URL="https://fred.stlouisfed.org/graph/fredgraph.csv?id=STWPOP"

echo "Fetching Zillow ZORI (rent index)..."
curl -s "$ZORI_URL" | grep -E '^RegionID|"?(Seattle|Bellevue)"?,city,WA' > "$TMP/zori.csv"
echo "Fetching Zillow ZHVI (home values, ~90MB streamed)..."
curl -s "$ZHVI_URL" | grep -E '^RegionID|"?(Seattle|Bellevue)"?,city,WA' > "$TMP/zhvi.csv"
echo "Fetching FRED 30-yr mortgage rate..."
curl -s "$MORTGAGE_URL" > "$TMP/mortgage.csv"
echo "Fetching FRED metro population (STWPOP)..."
curl -s "$POP_URL" > "$TMP/pop.csv"

DATE=$(date +%Y-%m-%d)

python3 - "$HTML" "$DATE" "$TMP/zori.csv" "$TMP/zhvi.csv" "$TMP/mortgage.csv" "$TMP/pop.csv" << 'PYEOF'
import sys, re, csv, json
from collections import defaultdict

html_path, date, zori_path, zhvi_path, mortgage_path, pop_path = sys.argv[1:7]
MONTHS_KEPT = 120  # 10 years

def load_series(path):
    with open(path) as f:
        rows = list(csv.reader(f))
    dates = rows[0][8:]
    out = {}
    for r in rows[1:]:
        if r[2] in ("Seattle", "Bellevue") and r[3] == "city" and r[5] == "WA":
            out[r[2].lower()] = dict(zip(dates, r[8:]))
    if set(out) != {"seattle", "bellevue"}:
        sys.exit(f"ERROR: expected Seattle+Bellevue rows in {path}, got {sorted(out)}")
    return out

def load_fred(path):
    """FRED CSV: observation_date,VALUE — returns [(date, float)] skipping blanks."""
    with open(path) as f:
        rows = list(csv.reader(f))
    if not rows or rows[0][0] != "observation_date":
        sys.exit(f"ERROR: unexpected FRED CSV header in {path}: {rows[:1]}")
    return [(r[0], float(r[1])) for r in rows[1:] if len(r) >= 2 and r[1] not in ("", ".")]

rent, home = load_series(zori_path), load_series(zhvi_path)

# Months where all four series have values, most recent MONTHS_KEPT
common = sorted(
    m for m in set(rent["seattle"]) & set(rent["bellevue"]) & set(home["seattle"]) & set(home["bellevue"])
    if rent["seattle"][m] and rent["bellevue"][m] and home["seattle"][m] and home["bellevue"][m]
)[-MONTHS_KEPT:]
if len(common) < 24:
    sys.exit(f"ERROR: only {len(common)} usable months — refusing to embed")

# Mortgage rate: monthly average of the weekly series, aligned to the Zillow months
by_month = defaultdict(list)
for d, v in load_fred(mortgage_path):
    by_month[d[:7]].append(v)
months = [m[:7] for m in common]
missing = [m for m in months if m not in by_month]
if missing:
    sys.exit(f"ERROR: mortgage series missing months {missing[:5]} — refusing to embed")
mortgage = [round(sum(by_month[m]) / len(by_month[m]), 2) for m in months]

# Metro population: annual, thousands -> persons
pop_rows = load_fred(pop_path)
if len(pop_rows) < 12:
    sys.exit(f"ERROR: only {len(pop_rows)} population rows — refusing to embed")
pop_rows = pop_rows[-12:]  # 12 years -> 11 growth bars, chart keeps the last 10
pop = {"years": [int(d[:4]) for d, _ in pop_rows], "value": [round(v * 1000) for _, v in pop_rows]}

data = {
    "months": months,
    "rent": {c: [round(float(rent[c][m])) for m in common] for c in ("seattle", "bellevue")},
    "home": {c: [round(float(home[c][m])) for m in common] for c in ("seattle", "bellevue")},
    "mortgage": mortgage,
    "pop": pop,
}

# Escape "<" (as the JS string escape backslash-u003c) so nothing can break out of
# the script tag when the data is embedded in HTML.
new_const = "const MARKET_DATA = " + json.dumps(data, separators=(",", ":")).replace("<", "\\u003c") + ";"
new_comment = f"// ── Market data (Zillow ZORI/ZHVI + FRED, pre-fetched {date}) ──"

with open(html_path) as f:
    html = f.read()

html, n = re.subn(
    r'// ── Market data \(Zillow ZORI/ZHVI[^)]*\) ──\nconst MARKET_DATA = \{[^;]+\};',
    lambda m: new_comment + "\n" + new_const,
    html,
)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 MARKET_DATA replacement, made {n}")

with open(html_path, "w") as f:
    f.write(html)

print(f"Done — {len(common)} months x 4 series + mortgage + population written to index.html (through {common[-1][:7]})")
PYEOF
