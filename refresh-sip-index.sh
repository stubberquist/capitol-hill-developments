#!/usr/bin/env bash
# Refreshes the SeattleInProgress project index embedded in index.html.
# SIP blocks browser fetches from file:// origins, so the index is baked in as a static
# JS constant. Run this script whenever you want to pick up newly added DR projects.
# Also run weekly by .github/workflows/refresh-sip.yml.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$SCRIPT_DIR/index.html"

echo "Fetching SeattleInProgress project index..."
RAW_JSON=$(curl -s "https://www.seattleinprogress.com/api/geo?left=-122.54&right=-122.10&top=47.78&bottom=47.46")
DATE=$(date +%Y-%m-%d)

python3 - "$HTML" "$DATE" "$RAW_JSON" << 'PYEOF'
import sys, re, json

html_path, date, raw = sys.argv[1], sys.argv[2], sys.argv[3]

projects = json.loads(raw)
# Normalize keys to match the runtime lookup (normalizeAddr): uppercase, collapsed whitespace
index = {" ".join(p["address"].split()).upper(): p["id"] for p in projects}
count = len(index)

# Escape "<" (as the JS string escape backslash-u003c) so an address containing
# "</script>" can't break out of the script tag when the index is embedded in HTML.
new_index = json.dumps(index, separators=(",", ":")).replace("<", "\\u003c")

new_const = f"const SIP_INDEX = {new_index};"
new_comment = f"// ── SeattleInProgress index (pre-fetched {date}, {count} active DR projects) ──"

with open(html_path) as f:
    html = f.read()

html, n = re.subn(
    r'// ── SeattleInProgress index \(pre-fetched [^)]+\) ──\nconst SIP_INDEX = \{[^;]+\};',
    lambda m: new_comment + "\n" + new_const,
    html,
)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 SIP_INDEX replacement, made {n}")

with open(html_path, "w") as f:
    f.write(html)

print(f"Done — {count} projects written to index.html")
PYEOF
