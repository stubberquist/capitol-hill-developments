#!/usr/bin/env bash
# Refreshes the SeattleInProgress project index embedded in index.html.
# SIP blocks browser fetches from file:// origins, so the index is baked in as a static
# JS constant. Run this script whenever you want to pick up newly added DR projects.
# Also run weekly by .github/workflows/refresh-sip.yml.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$SCRIPT_DIR/index.html"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching SeattleInProgress project index..."
curl -s "https://www.seattleinprogress.com/api/geo?left=-122.54&right=-122.10&top=47.78&bottom=47.46" > "$TMP/sip.json"
DATE=$(date +%Y-%m-%d)

python3 - "$HTML" "$DATE" "$TMP/sip.json" << 'PYEOF'
import sys, re, json

html_path, date, json_path = sys.argv[1:4]

with open(json_path) as f:
    projects = json.load(f)
# Normalize keys to match the runtime lookup (normalizeAddr): uppercase, collapsed whitespace
index = {" ".join(p["address"].split()).upper(): p["id"] for p in projects}
count = len(index)
if count < 50:
    sys.exit(f"ERROR: only {count} projects returned — refusing to embed a suspiciously small index")

# Escape "<" (as the JS string escape backslash-u003c) so an address containing
# "</script>" can't break out of the script tag when the index is embedded in HTML.
new_index = json.dumps(index, separators=(",", ":")).replace("<", "\\u003c")

new_block = (
    f"// ── SeattleInProgress index (pre-fetched {date}, {count} active DR projects) ──\n"
    f'const SIP_FETCHED = "{date}";\n'
    f"const SIP_INDEX = {new_index};"
)

with open(html_path) as f:
    html = f.read()

html, n = re.subn(
    r'// ── SeattleInProgress index \(pre-fetched [^)]+\) ──\n'
    r'(?:const SIP_FETCHED = "[^"]*";\n)?'
    r'const SIP_INDEX = \{[^;]+\};',
    lambda m: new_block,
    html,
)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 SIP_INDEX replacement, made {n}")

with open(html_path, "w") as f:
    f.write(html)

print(f"Done — {count} projects written to index.html")
PYEOF
