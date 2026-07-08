#!/usr/bin/env bash
# Refreshes the SeattleInProgress project index embedded in index.html.
# SIP blocks browser fetches from file:// origins, so the index is baked in as a static
# JS constant. Run this script whenever you want to pick up newly added DR projects.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$SCRIPT_DIR/index.html"

echo "Fetching SeattleInProgress project index..."
NEW_INDEX=$(curl -s "https://www.seattleinprogress.com/api/geo?left=-122.54&right=-122.10&top=47.78&bottom=47.46" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({p['address']:p['id'] for p in d}, separators=(',',':')))")

COUNT=$(echo "$NEW_INDEX" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
DATE=$(date +%Y-%m-%d)

echo "Got $COUNT projects. Updating index.html..."

# Replace the SIP_INDEX constant (single line) and its date comment
python3 - "$HTML" "$NEW_INDEX" "$COUNT" "$DATE" << 'PYEOF'
import sys, re

html_path, new_index, count, date = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(html_path) as f:
    html = f.read()

new_const = f"const SIP_INDEX = {new_index};"
new_comment = f"// ── SeattleInProgress index (pre-fetched {date}, {count} active DR projects) ──"

html = re.sub(
    r'// ── SeattleInProgress index \(pre-fetched [^)]+\) ──\nconst SIP_INDEX = \{[^;]+\};',
    new_comment + "\n" + new_const,
    html
)

with open(html_path, "w") as f:
    f.write(html)

print(f"Done — {count} projects written to index.html")
PYEOF
