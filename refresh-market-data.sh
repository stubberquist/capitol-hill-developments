#!/usr/bin/env bash
# Refreshes the Zillow market data (ZORI rent index + ZHVI home value index)
# embedded in index.html. The source CSVs are too large to fetch in the browser
# (~5MB / ~90MB), so the Seattle + Bellevue series are baked in as a small constant.
# Run weekly by .github/workflows/refresh-sip.yml; Zillow updates monthly.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$SCRIPT_DIR/index.html"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ZORI_URL="https://files.zillowstatic.com/research/public_csvs/zori/City_zori_uc_sfrcondomfr_sm_month.csv"
ZHVI_URL="https://files.zillowstatic.com/research/public_csvs/zhvi/City_zhvi_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv"

echo "Fetching Zillow ZORI (rent index)..."
curl -s "$ZORI_URL" | grep -E '^RegionID|"?(Seattle|Bellevue)"?,city,WA' > "$TMP/zori.csv"
echo "Fetching Zillow ZHVI (home values, ~90MB streamed)..."
curl -s "$ZHVI_URL" | grep -E '^RegionID|"?(Seattle|Bellevue)"?,city,WA' > "$TMP/zhvi.csv"

DATE=$(date +%Y-%m-%d)

python3 - "$HTML" "$DATE" "$TMP/zori.csv" "$TMP/zhvi.csv" << 'PYEOF'
import sys, re, csv, json

html_path, date, zori_path, zhvi_path = sys.argv[1:5]
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

rent, home = load_series(zori_path), load_series(zhvi_path)

# Months where all four series have values, most recent MONTHS_KEPT
common = sorted(
    m for m in set(rent["seattle"]) & set(rent["bellevue"]) & set(home["seattle"]) & set(home["bellevue"])
    if rent["seattle"][m] and rent["bellevue"][m] and home["seattle"][m] and home["bellevue"][m]
)[-MONTHS_KEPT:]
if len(common) < 24:
    sys.exit(f"ERROR: only {len(common)} usable months — refusing to embed")

data = {
    "months": [m[:7] for m in common],
    "rent": {c: [round(float(rent[c][m])) for m in common] for c in ("seattle", "bellevue")},
    "home": {c: [round(float(home[c][m])) for m in common] for c in ("seattle", "bellevue")},
}

# Escape "<" (as the JS string escape backslash-u003c) so nothing can break out of
# the script tag when the data is embedded in HTML.
new_const = "const MARKET_DATA = " + json.dumps(data, separators=(",", ":")).replace("<", "\\u003c") + ";"
new_comment = f"// ── Market data (Zillow ZORI/ZHVI, pre-fetched {date}) ──"

with open(html_path) as f:
    html = f.read()

html, n = re.subn(
    r'// ── Market data \(Zillow ZORI/ZHVI, pre-fetched [^)]+\) ──\nconst MARKET_DATA = \{[^;]+\};',
    lambda m: new_comment + "\n" + new_const,
    html,
)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 MARKET_DATA replacement, made {n}")

with open(html_path, "w") as f:
    f.write(html)

print(f"Done — {len(common)} months x 4 series written to index.html (through {common[-1][:7]})")
PYEOF
