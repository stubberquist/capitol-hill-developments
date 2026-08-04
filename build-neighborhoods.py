#!/usr/bin/env python3
"""Regenerate the embedded Seattle neighborhood polygons in index.html.

Source of truth is the Seattle City Clerk's Neighborhood Map Atlas sub-areas
(S_HOOD), served from the same ArcGIS host the app already uses for SDOT, so no
CSP change is needed to refetch:

  services.arcgis.com/ZOyb2t4B0UYuYNYH/.../nma_nhoods_sub/FeatureServer/0

Why polygons at all: neighborhoods used to be hand-drawn lat/lon bounding boxes.
They overlapped badly — 32% of $1M+ permits fell in two or more boxes at once and
were double-counted in the "Units Added by Area" chart — and the Capitol Hill box
ran ~825m west of I-5, so only 36% of what the app called Capitol Hill actually
was. Denny Triangle, South Lake Union and First Hill were all swept into it.

The atlas carries a disclaimer that it is an unofficial delineation used for
indexing City Clerk records. There is no official Seattle neighborhood map; this
is the closest thing to a shared convention, so it is what we align to.

Usage:  python3 build-neighborhoods.py [--check]
        --check verifies index.html is already up to date (exit 1 if not).
"""
import json
import re
import sys
import urllib.parse
import urllib.request

LAYER = ("https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services"
         "/nma_nhoods_sub/FeatureServer/0/query")
# ~22m. Verified to classify every test point identically to full-resolution
# geometry, at 1/24th the size (1613 KB -> 68 KB before grouping).
OFFSET = 0.0002
PREC = 4          # ~11m, finer than the simplification so not the limiting factor
INDEX = "index.html"
BEGIN = "// <generated:neighborhoods> — regenerate with build-neighborhoods.py"
END = "// </generated:neighborhoods>"

# Display name -> atlas S_HOOD sub-areas. Every one of the 94 sub-areas appears
# exactly once (asserted below), so these partition the city: a permit lands in
# one neighborhood or none, never two.
GROUPS = {
    "Belltown":                  ["Belltown"],
    "Denny Triangle":            ["Denny Triangle"],
    "Downtown":                  ["Central Business District", "Pike-Market"],
    "South Lake Union":          ["South Lake Union", "Westlake"],
    "Capitol Hill":              ["Broadway", "Stevens"],
    "First Hill":                ["First Hill"],
    "Central District":          ["Atlantic", "Harrison/Denny-Blaine", "Leschi", "Mann", "Minor"],
    "Madison Park / Madrona":    ["Madison Park", "Madrona"],
    "Montlake / Portage Bay":    ["Montlake", "Portage Bay"],
    "Pioneer Square":            ["Pioneer Square"],
    "Yesler Terrace":            ["Yesler Terrace"],
    "International District":    ["International District"],
    "Eastlake":                  ["Eastlake"],
    "Queen Anne":                ["East Queen Anne", "North Queen Anne", "West Queen Anne"],
    "Uptown / Lower Queen Anne": ["Lower Queen Anne"],
    "Interbay":                  ["Interbay"],
    "Magnolia":                  ["Briarcliff", "Lawton Park", "Southeast Magnolia"],
    "Fremont":                   ["Fremont"],
    "Green Lake / Wallingford":  ["Green Lake", "Wallingford"],
    "Greenwood / Phinney Ridge": ["Greenwood", "Phinney Ridge", "Crown Hill"],
    "Bitter Lake / Broadview":   ["Bitter Lake", "Broadview", "North Beach/Blue Ridge"],
    "Ballard":                   ["Ballard", "Loyal Heights", "Sunset Hill",
                                  "West Woodland", "Whittier Heights"],
    "University District":       ["University District", "University Heights"],
    "University of Washington":  ["University of Washington"],
    "Ravenna / Roosevelt":       ["Ravenna", "Roosevelt", "Bryant", "Wedgwood"],
    "Laurelhurst / Sand Point":  ["Laurelhurst", "Sand Point", "View Ridge", "Windermere"],
    "Northgate":                 ["Haller Lake", "Licton Springs", "Maple Leaf", "Pinehurst"],
    "Lake City":                 ["Cedar Park", "Matthews Beach", "Meadowbrook",
                                  "Olympic Hills", "Victory Heights"],
    "Beacon Hill":               ["Holly Park", "Mid-Beacon Hill", "North Beacon Hill",
                                  "South Beacon Hill"],
    "Columbia City":             ["Columbia City"],
    "Mount Baker":               ["Mount Baker"],
    "Seward Park":               ["Seward Park"],
    "Rainier Valley":            ["Brighton", "Dunlap", "Rainier Beach", "Rainier View"],
    "Georgetown / South Park":   ["Georgetown", "South Park"],
    "SODO / Industrial District":["SODO", "Industrial District", "Harbor Island"],
    "West Seattle":              ["Alki", "Arbor Heights", "Fairmount Park", "Fauntleroy",
                                  "Gatewood", "Genesee", "North Admiral", "Seaview"],
    "Delridge":                  ["High Point", "Highland Park", "North Delridge",
                                  "Riverview", "Roxhill", "South Delridge"],
}


def fetch():
    params = urllib.parse.urlencode({
        "where": "1=1", "outFields": "L_HOOD,S_HOOD", "outSR": "4326",
        "f": "geojson", "resultRecordCount": 500, "maxAllowableOffset": OFFSET,
    })
    with urllib.request.urlopen(f"{LAYER}?{params}", timeout=60) as r:
        data = json.load(r)
    if data.get("exceededTransferLimit"):
        sys.exit("ERROR: transfer limit hit; the layer grew past one page")
    feats = data.get("features") or []
    if not feats:
        sys.exit(f"ERROR: no features returned: {str(data)[:300]}")
    return feats


def zoom_for(span_lon, span_lat):
    span = max(span_lon, span_lat)
    for limit, z in ((0.012, 15), (0.030, 14), (0.065, 13)):
        if span <= limit:
            return z
    return 12


def build(feats):
    by_sub = {}
    for f in feats:
        by_sub.setdefault(f["properties"]["S_HOOD"], []).append(f["geometry"])

    known = set(by_sub)
    mapped = [s for subs in GROUPS.values() for s in subs]
    unknown = sorted(set(mapped) - known)
    if unknown:
        sys.exit(f"ERROR: groups reference sub-areas not in the atlas: {unknown}")
    unmapped = sorted(known - set(mapped))
    if unmapped:
        sys.exit(f"ERROR: {len(unmapped)} atlas sub-areas unmapped: {unmapped}")
    dupes = sorted({s for s in mapped if mapped.count(s) > 1})
    if dupes:
        sys.exit(f"ERROR: sub-areas in more than one group: {dupes}")

    lines, vertices = [], 0
    for name, subs in GROUPS.items():
        rings = []
        for sub in subs:
            for g in by_sub[sub]:
                polys = (g["coordinates"] if g["type"] == "MultiPolygon"
                         else [g["coordinates"]])
                for poly in polys:
                    # Outer ring only. The atlas sub-areas have no holes; dropping one
                    # would silently widen a neighborhood, so fail loudly instead.
                    if len(poly) > 1:
                        sys.exit(f"ERROR: {name}/{sub} has {len(poly)-1} hole(s)")
                    rings.append([[round(x, PREC), round(y, PREC)] for x, y in poly[0]])
        pts = [p for r in rings for p in r]
        vertices += len(pts)
        lons, lats = [p[0] for p in pts], [p[1] for p in pts]
        lo_lon, hi_lon, lo_lat, hi_lat = min(lons), max(lons), min(lats), max(lats)
        lines.append(
            f'  {json.dumps(name)}: {{ minLat:{lo_lat}, maxLat:{hi_lat}, '
            f'minLon:{lo_lon}, maxLon:{hi_lon}, '
            f'center:[{round((lo_lat+hi_lat)/2, 4)},{round((lo_lon+hi_lon)/2, 4)}], '
            f'zoom:{zoom_for(hi_lon-lo_lon, hi_lat-lo_lat)}, '
            f'rings:{json.dumps(rings, separators=(",", ":"))} }},'
        )
    return "\n".join(lines), vertices


def main():
    body, vertices = build(fetch())
    block = f"{BEGIN}\nconst NEIGHBORHOODS = {{\n{body}\n}};\n{END}"

    html = open(INDEX, encoding="utf-8").read()
    pattern = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
    if not pattern.search(html):
        sys.exit(f"ERROR: markers not found in {INDEX}; expected {BEGIN!r}")
    updated = pattern.sub(lambda _: block, html, count=1)

    if "--check" in sys.argv:
        if updated != html:
            sys.exit(f"{INDEX} is stale — run: python3 build-neighborhoods.py")
        print(f"{INDEX} is up to date ({len(GROUPS)} neighborhoods)")
        return

    open(INDEX, "w", encoding="utf-8").write(updated)
    print(f"{len(GROUPS)} neighborhoods, {vertices} vertices, "
          f"{len(block)/1024:.0f} KB embedded into {INDEX}")


if __name__ == "__main__":
    main()
