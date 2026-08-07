#!/usr/bin/env bash
# Refreshes the pending-rezone index embedded in index.html.
#
# Seattle's One Seattle Plan rezone is landing in phases, and the city's proposal layer
# does NOT track that: its ZONING column is a snapshot frozen before the December 2025
# middle-housing ordinance, so it still lists NR1/NR2/NR3/RSL — zones that no longer
# exist. Diffing that column against the proposal (the obvious reading of the data)
# reports ~700 already-adopted changes as if they were still up for a vote.
#
# The only way to tell pending from settled is to compare the proposal against the LIVE
# zoning layer. That's two full polygon tables and a point-in-polygon pass per shape —
# far too much to do in the browser on every load — so it happens here, weekly, and the
# result is baked into index.html as a list of the OBJECTIDs that still represent a real
# change, plus the zone each one is changing FROM.
#
# Run weekly by .github/workflows/refresh-sip.yml.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$SCRIPT_DIR/index.html"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOST="https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services"
PROPOSAL="$HOST/zoning_proposal_public_view/FeatureServer/4628/query"
LIVE="$HOST/Current_Land_Use_Zoning_Detail_2/FeatureServer/0/query"
# ~11m, matching ZONING_OFFSET in index.html so the geometry indexed here is the same
# geometry the browser hit-tests against.
OFFSET="0.0001"
DATE=$(date +%Y-%m-%d)

# Both layers cap responses at 2,000 rows, so page until exceededTransferLimit clears.
fetch_all() {   # fetch_all <url> <where> <outFields> <extra-args...> > file
  local url="$1" where="$2" fields="$3"; shift 3
  local off=0 page
  echo "["
  while :; do
    page="$TMP/page.json"
    curl -sf -G "$url" \
      --data-urlencode "where=$where" \
      --data-urlencode "outFields=$fields" \
      --data-urlencode "outSR=4326" \
      --data-urlencode "returnGeometry=true" \
      --data-urlencode "resultRecordCount=2000" \
      --data-urlencode "resultOffset=$off" \
      --data-urlencode "maxAllowableOffset=$OFFSET" \
      "$@" \
      --data-urlencode "f=json" > "$page"
    [ "$off" -gt 0 ] && echo ","
    cat "$page"
    if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$page')).get('exceededTransferLimit') else 1)"; then
      break
    fi
    off=$((off + 2000))
    [ "$off" -gt 20000 ] && { echo "ERROR: runaway pagination" >&2; exit 1; }
  done
  echo "]"
}

echo "Fetching proposed zoning (Centers and Corridors)..."
fetch_all "$PROPOSAL" "v2p2_zoning IS NOT NULL" \
  "OBJECTID,ZONING,v2p2_zoning,v2p2_zoning_full,rezone_view_category,v1_name" \
  --data-urlencode "returnCentroid=true" > "$TMP/proposal.json"

echo "Fetching live zoning..."
fetch_all "$LIVE" "1=1" "ZONING" > "$TMP/live.json"

python3 - "$HTML" "$DATE" "$TMP/proposal.json" "$TMP/live.json" << 'PYEOF'
import sys, re, json

html_path, date, proposal_path, live_path = sys.argv[1:5]

def features(path):
    out = []
    for page in json.load(open(path)):
        if "error" in page:
            sys.exit(f"ERROR: ArcGIS returned {page['error']}")
        out.extend(page.get("features", []))
    return out

proposal = features(proposal_path)
live     = features(live_path)
print(f"  proposal polygons: {len(proposal)}   live zoning polygons: {len(live)}")

# Same ray-casting rule the browser uses (index.html: pointInRings). Crossings accumulate
# across every ring rather than being tested ring-by-ring, so a hole reads as outside.
def point_in_rings(lat, lon, rings):
    inside = False
    for ring in rings:
        j = len(ring) - 1
        for i in range(len(ring)):
            xi, yi = ring[i][0], ring[i][1]
            xj, yj = ring[j][0], ring[j][1]
            if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
                inside = not inside
            j = i
    return inside

def index_zones(feats):
    out = []
    for f in feats:
        rings = (f.get("geometry") or {}).get("rings")
        if not rings:
            continue
        xs = [p[0] for r in rings for p in r]
        ys = [p[1] for r in rings for p in r]
        out.append((min(ys), max(ys), min(xs), max(xs), rings, f["attributes"]))
    return out

def zone_hit(zones, lat, lon):
    for lo_y, hi_y, lo_x, hi_x, rings, attrs in zones:
        if lat < lo_y or lat > hi_y or lon < lo_x or lon > hi_x:
            continue
        if point_in_rings(lat, lon, rings):
            return attrs
    return None

live_idx = index_zones(live)

# To ask "what is the zoning here today?" we need points that are genuinely inside the
# proposal polygon. ArcGIS's centroid is a center of mass, which falls outside concave and
# ring-shaped polygons, so it is verified before use and vertex-based probes fill in when
# it misses.
#
# Several points, not one: proposal boundaries were drawn around centers and transit
# corridors, not around existing zone edges, so a polygon can straddle two live zones. A
# single probe then labels the whole shape with whichever zone it happened to land in —
# that mislabelled 2 of 60 permits when the badge was first checked against the server.
#
# The probes are a grid over the polygon's bounding box, filtered to those that land
# inside. Points ON an edge are deliberately avoided: proposal boundaries were often cut
# along existing zone edges, so an edge-sitting probe resolves to whichever side the
# ray-cast happens to pick and reports a spurious split. An earlier version used edge
# midpoints and called 63% of polygons "mixed"; grid interiors put that at a few percent.
GRID = 10

def interior_points(f):
    rings = (f.get("geometry") or {}).get("rings")
    if not rings:
        return []
    xs = [p[0] for r in rings for p in r]
    ys = [p[1] for r in rings for p in r]
    lo_x, hi_x, lo_y, hi_y = min(xs), max(xs), min(ys), max(ys)
    found = []
    for i in range(GRID):
        for j in range(GRID):
            x = lo_x + (hi_x - lo_x) * (i + 0.5) / GRID
            y = lo_y + (hi_y - lo_y) * (j + 0.5) / GRID
            if point_in_rings(y, x, rings):
                found.append((x, y))
    if found:
        return found
    # Slivers too thin for the grid to catch: fall back to the centroid, verified inside,
    # then to the vertex average.
    c = f.get("centroid")
    if c and point_in_rings(c["y"], c["x"], rings):
        return [(c["x"], c["y"])]
    ring = rings[0]
    cx = sum(p[0] for p in ring) / len(ring)
    cy = sum(p[1] for p in ring) / len(ring)
    if point_in_rings(cy, cx, rings):
        return [(cx, cy)]
    return []

pending, settled, undetermined, mixed, partial = {}, 0, 0, 0, 0
for f in proposal:
    a = f["attributes"]
    proposed = (a.get("v2p2_zoning_full") or a.get("v2p2_zoning") or "").strip()
    pts = interior_points(f)
    if not proposed or not pts:
        undetermined += 1
        continue
    tally = {}
    for x, y in pts:
        hit = zone_hit(live_idx, y, x)
        z = (hit or {}).get("ZONING", "").strip()
        if z:
            tally[z] = tally.get(z, 0) + 1
    if not tally:
        undetermined += 1        # outside every live polygon (water, city edge)
        continue

    ranked = sorted(tally.items(), key=lambda kv: -kv[1])
    # Two probes are enough to call a split. Grid points are strictly interior, so a second
    # zone showing up twice is a real overlap rather than a boundary artifact — and a
    # minority corner is exactly the case a majority-wins rule would label wrongly. One
    # Greenwood polygon runs 85% NR / 15% LR2; the permits in it sit in the 15%.
    is_mixed = len(ranked) > 1 and ranked[1][1] >= 2

    if not is_mixed and ranked[0][0] == proposed:
        settled += 1             # already adopted throughout this shape — not pending
        continue
    # Part of this shape already carries the proposed zoning and part doesn't, and nothing
    # here can say which part a given permit falls in. Dropped rather than badged: over-
    # claiming "a rezone is coming" where it has already landed is the failure this whole
    # script exists to prevent, and a missing badge is the cheaper error.
    if is_mixed and proposed in tally:
        partial += 1
        continue
    # Where the probes genuinely disagree the polygon spans more than one live zone, so no
    # single "from" is true of it. Recorded with an empty from: the badge then states only
    # what the zoning is changing to, which is the part that stays correct.
    if is_mixed:
        mixed += 1
        pending[a["OBJECTID"]] = ""
    else:
        pending[a["OBJECTID"]] = ranked[0][0]

print(f"  still pending: {len(pending)}   already adopted: {settled}   "
      f"undetermined: {undetermined}\n"
      f"  spanning >1 live zone: {mixed}   dropped as part-adopted: {partial}")

# Guardrails. The counts move a little as the city edits either layer, but a collapse means
# the schema changed under us (a v2p3 column, a republished layer with new OBJECTIDs) and
# baking the result would quietly blank the feature instead of failing.
if len(pending) < 300:
    sys.exit(f"ERROR: only {len(pending)} pending rezones — refusing to embed, check the layer schema")
if undetermined > len(proposal) * 0.1:
    sys.exit(f"ERROR: {undetermined}/{len(proposal)} polygons undetermined — geometry or projection looks wrong")

new_index = json.dumps({str(k): v for k, v in sorted(pending.items())},
                       separators=(",", ":")).replace("<", "\\u003c")

new_block = (
    f"// ── Pending rezone index (computed {date}, {len(pending)} polygons still awaiting Council) ──\n"
    f'const REZONE_FETCHED = "{date}";\n'
    f"const REZONE_PENDING = {new_index};"
)

with open(html_path) as f:
    html = f.read()

# Emitted as a single line, so `.*` spans it exactly (it stops at the newline).
html, n = re.subn(
    r'// ── Pending rezone index \(computed [^)]+\) ──\n'
    r'(?:const REZONE_FETCHED = "[^"]*";\n)?'
    r'const REZONE_PENDING = \{.*\};',
    lambda m: new_block,
    html,
)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 REZONE_PENDING replacement, made {n}")

with open(html_path, "w") as f:
    f.write(html)

print(f"Done — {len(pending)} pending rezone polygons written to index.html")
PYEOF
