#!/usr/bin/env bash
# Builds whats-new.html + feed.xml: notable permits (>= $5M value or >= 20 homes)
# filed in Seattle or Bellevue in the last 7 days.
# Run weekly by .github/workflows/refresh-sip.yml, after the data refresh steps.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SINCE=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d)
TODAY=$(date -u +%Y-%m-%d)
TOKEN="8TWYR3dr4BMUJcfxCbdwGw7pv"

echo "Fetching notable Seattle filings since $SINCE..."
curl -s -G "https://data.seattle.gov/resource/76t5-zqzr.json" \
  --data-urlencode "\$select=permitnum,originaladdress1,description,estprojectcost,housingunitsadded,applieddate" \
  --data-urlencode "\$where=applieddate >= '$SINCE' AND (estprojectcost >= 5000000 OR housingunitsadded >= 20)" \
  --data-urlencode "\$order=estprojectcost DESC" \
  --data-urlencode "\$limit=200" \
  --data-urlencode "\$\$app_token=$TOKEN" > "$TMP/seattle.json"

echo "Fetching notable Bellevue filings since $SINCE..."
curl -s -G "https://services1.arcgis.com/EYzEZbDhXZjURPbP/arcgis/rest/services/Bellevue_Permits/FeatureServer/0/query" \
  --data-urlencode "where=APPLIEDDATE >= DATE '$SINCE' AND (VALUATION >= 5000000 OR DWELLINGUNITSCREATED >= 20)" \
  --data-urlencode "outFields=PERMITNUMBER,SITEADDRESS,PROJECTDESCRIPTION,VALUATION,DWELLINGUNITSCREATED,APPLIEDDATE" \
  --data-urlencode "orderByFields=VALUATION DESC" \
  --data-urlencode "returnGeometry=false" \
  --data-urlencode "f=json" > "$TMP/bellevue.json"

python3 - "$SCRIPT_DIR" "$SINCE" "$TODAY" "$TMP/seattle.json" "$TMP/bellevue.json" << 'PYEOF'
import sys, json, html
from datetime import datetime, timezone
from urllib.parse import quote
from xml.sax.saxutils import escape as xesc

out_dir, since, today, sea_path, bel_path = sys.argv[1:6]
SITE = "https://stubberquist.github.io/capitol-hill-developments"

def fmt_money(v):
    v = float(v or 0)
    if v >= 1e9: return f"${v/1e9:.2f}B"
    if v >= 1e6: return f"${v/1e6:.1f}M"
    if v >= 1e3: return f"${v/1e3:.0f}K"
    return f"${v:.0f}"

items = []
with open(sea_path) as f:
    for r in json.load(f):
        items.append({
            "city": "Seattle", "num": r.get("permitnum", ""),
            "addr": r.get("originaladdress1", "Address unknown"),
            "desc": (r.get("description") or "").strip(),
            "value": float(r.get("estprojectcost") or 0),
            "units": int(float(r.get("housingunitsadded") or 0)),
            "date": (r.get("applieddate") or "")[:10],
            "url": f"https://services.seattle.gov/portal/customize/LinkToRecord.aspx?altId={quote(r.get('permitnum',''), safe='')}",
        })
with open(bel_path) as f:
    for feat in json.load(f).get("features", []):
        a = feat["attributes"]
        ts = a.get("APPLIEDDATE")
        items.append({
            "city": "Bellevue", "num": a.get("PERMITNUMBER", ""),
            "addr": a.get("SITEADDRESS") or "Address unknown",
            "desc": (a.get("PROJECTDESCRIPTION") or "").strip(),
            "value": float(a.get("VALUATION") or 0),
            "units": int(a.get("DWELLINGUNITSCREATED") or 0),
            "date": datetime.fromtimestamp(ts / 1000, tz=timezone.utc).strftime("%Y-%m-%d") if ts else "",
            "url": f"https://permitsearch.mybuildingpermit.com/PermitDetails/{quote(a.get('PERMITNUMBER',''), safe='')}/BELLEVUE",
        })

items.sort(key=lambda i: i["value"], reverse=True)
e = html.escape

# ── whats-new.html ──
rows = "".join(f"""
  <div class="item">
    <div class="item-head">
      <span class="city {i['city'].lower()}">{i['city']}</span>
      <a href="{e(i['url'])}" target="_blank" rel="noopener">{e(i['num'])}</a>
      <span class="val">{fmt_money(i['value'])}</span>
      {f'<span class="units">{i["units"]} homes</span>' if i['units'] else ''}
    </div>
    <div class="addr">{e(i['addr'])} · filed {e(i['date'])}</div>
    <div class="desc">{e(i['desc'][:280])}</div>
  </div>""" for i in items) or '<p class="empty">No filings over $5M or 20+ homes this week.</p>'

page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>What's New — Puget Sound Large Developments</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<link rel="alternate" type="application/rss+xml" title="New large developments" href="feed.xml">
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ background:#0f1117; color:#e2e8f0; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; font-size:14px; padding:32px 16px; }}
  .wrap {{ max-width:760px; margin:0 auto; }}
  h1 {{ font-size:22px; margin-bottom:4px; }}
  .sub {{ color:#64748b; font-size:12px; margin-bottom:24px; }}
  .sub a {{ color:#6c8ef5; text-decoration:none; }}
  .item {{ background:#1a1d27; border:1px solid #2e3350; border-radius:10px; padding:16px; margin-bottom:12px; }}
  .item-head {{ display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-bottom:6px; }}
  .item-head a {{ color:#6c8ef5; font-family:monospace; text-decoration:none; }}
  .city {{ font-size:10px; font-weight:700; letter-spacing:0.5px; text-transform:uppercase; padding:2px 7px; border-radius:4px; }}
  .city.seattle {{ background:rgba(108,142,245,0.15); color:#6c8ef5; }}
  .city.bellevue {{ background:rgba(251,146,60,0.15); color:#fb923c; }}
  .val {{ color:#34d399; font-weight:700; }}
  .units {{ color:#a78bfa; font-size:12px; }}
  .addr {{ font-weight:600; margin-bottom:6px; }}
  .desc {{ color:#94a3b8; font-size:13px; line-height:1.5; }}
  .empty {{ color:#64748b; }}
</style>
</head>
<body><div class="wrap">
<h1>What's New This Week</h1>
<div class="sub">Notable permits (≥ $5M or ≥ 20 homes) filed {e(since)} → {e(today)} ·
  <a href="index.html">← back to the tracker</a> · <a href="feed.xml">RSS</a></div>
{rows}
</div></body></html>
"""
with open(f"{out_dir}/whats-new.html", "w") as f:
    f.write(page)

# ── feed.xml (RSS 2.0) ──
now_rfc = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
def rfc822(d):
    try: return datetime.strptime(d, "%Y-%m-%d").replace(tzinfo=timezone.utc).strftime("%a, %d %b %Y 08:00:00 GMT")
    except ValueError: return now_rfc

def item_title(i):
    units = f" · {i['units']} homes" if i["units"] else ""
    return f"{i['city']}: {fmt_money(i['value'])}{units} — {i['addr']}"

feed_items = "".join(f"""
  <item>
    <title>{xesc(item_title(i))}</title>
    <link>{xesc(i['url'])}</link>
    <guid isPermaLink="false">{xesc(i['num'])}</guid>
    <pubDate>{rfc822(i['date'])}</pubDate>
    <description>{xesc(i['desc'][:400])}</description>
  </item>""" for i in items)

feed = f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
  <title>Puget Sound Large Developments — New Filings</title>
  <link>{SITE}/whats-new.html</link>
  <description>Notable development permits (over $5M or 20+ homes) filed in Seattle and Bellevue in the last week</description>
  <lastBuildDate>{now_rfc}</lastBuildDate>
{feed_items}
</channel>
</rss>
"""
with open(f"{out_dir}/feed.xml", "w") as f:
    f.write(feed)

print(f"Done — {len(items)} notable filings → whats-new.html + feed.xml")
PYEOF
