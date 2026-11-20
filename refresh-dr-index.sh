#!/usr/bin/env bash
# Refreshes the design-proposal index embedded in index.html.
#
# Seattle's permit document library answers a JSON search per record, and the details
# window already uses it live. Cards can't: one request per card would be ~2,500 requests
# on every load. So once a week this asks the library about every land-use record the
# page's permits link to (relatedmup), picks the design proposal packet the details window
# would pick, and bakes {land-use id: document id} into the page. Cards then link the PDF
# directly, and the "Has design proposal" flag filters on it.
#
# Run weekly by .github/workflows/refresh-sip.yml.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$SCRIPT_DIR/index.html"
DATE=$(date +%Y-%m-%d)

python3 - "$HTML" "$DATE" << 'PYEOF'
import sys, re, json, time, urllib.request, urllib.parse, concurrent.futures as cf

html_path, date = sys.argv[1:3]
html = open(html_path, encoding="utf-8").read()

# Same population as the page: its MIN_VALUE and its base query.
m = re.search(r"const MIN_VALUE = ([\d_]+);", html)
if not m:
    sys.exit("ERROR: could not find MIN_VALUE in index.html")
min_value = int(m.group(1).replace("_", ""))

UA = {"User-Agent": "capitol-hill-developments design-proposal index (weekly)"}

def get_json(url, timeout=60, tries=3):
    err = None
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
                return json.load(r)
        except Exception as e:
            err = e
            time.sleep(2 * (i + 1))
    raise err

q = urllib.parse.urlencode({
    "$select": "relatedmup",
    "$where": f"estprojectcost >= {min_value} AND latitude IS NOT NULL AND relatedmup IS NOT NULL",
    "$limit": "50000",
})
rows = get_json(f"https://data.seattle.gov/resource/76t5-zqzr.json?{q}", timeout=120)
ids = sorted({x.strip() for r in rows for x in (r.get("relatedmup") or "").split(",") if x.strip()})
if len(ids) < 1000:
    sys.exit(f"ERROR: only {len(ids)} land-use ids from Socrata — refusing to build a suspiciously small index")
print(f"{len(ids)} land-use ids to look up")

# Keep in step with DR_PROPOSAL_TYPES in index.html: best first, newest within the best type.
PROPOSAL_TYPES = [
    "Design Review Recommendation Proposal - Final", "Design Review Proposal",
    "Design Review Recommendation Proposal - Draft", "Design Review EDG Proposal - Final",
    "Design Review EDG Proposal - Draft",
]
API = "https://web.seattle.gov/ecm/SearchService/searchByRef_Public/"

def pick(docs):
    for t in PROPOSAL_TYPES:
        hits = [d for d in docs if d.get("documentType") == t and d.get("id") is not None
                and str(d.get("documentWebExtension") or "").lower() == "pdf"]
        if hits:
            return max(hits, key=lambda d: str(d.get("documentDate") or ""))["id"]
    return None

def lookup(i):
    try:
        docs = get_json(API + urllib.parse.quote(i, safe=""))
        return i, (pick(docs) if isinstance(docs, list) else None), None
    except Exception as e:
        return i, None, str(e)

t0 = time.time()
index, failed = {}, []
with cf.ThreadPoolExecutor(6) as ex:
    for i, doc, err in ex.map(lookup, ids):
        if err: failed.append(i)
        elif doc is not None: index[i] = int(doc)
print(f"looked up {len(ids)} in {time.time() - t0:.0f}s: {len(index)} with a proposal, {len(failed)} failed")

# A library outage mid-run would otherwise bake a half-empty index and silently strip the
# link from hundreds of cards. Fail loudly instead; last week's index stays in place.
if len(failed) > len(ids) * 0.05:
    sys.exit(f"ERROR: {len(failed)} of {len(ids)} lookups failed — not replacing the index")
if len(index) < 400:
    sys.exit(f"ERROR: only {len(index)} proposals found — refusing to embed a suspiciously small index")

# Packed as "gap:docId,…" over the sorted numeric project numbers (every key is NNNNNNN-LU):
# 5.3 KB gzipped against 7.3 KB as a plain object, which matters against the size budget.
# Unpacked once at load by unpackDrIndex in index.html.
nums = sorted((int(k[:-3]), v) for k, v in index.items() if re.fullmatch(r"\d+-LU", k))
packed, prev = [], 0
for k, v in nums:
    packed.append(f"{k - prev}:{v}")
    prev = k
new_block = (
    f"// ── Design proposal index (pre-fetched {date}, {len(nums)} land-use records with a packet) ──\n"
    f'const DR_FETCHED = "{date}";\n'
    f'const DR_INDEX_PACKED = "{",".join(packed)}";'
)
# Single line, so `.*` spans exactly the constant (see refresh-rezone-index.sh).
html, n = re.subn(
    r'// ── Design proposal index \(pre-fetched [^)]+\) ──\n'
    r'const DR_FETCHED = "[^"]*";\n'
    r'const DR_INDEX_PACKED = "[^"\n]*";',
    lambda _: new_block, html)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 DR_INDEX replacement, made {n}")
open(html_path, "w", encoding="utf-8").write(html)
print(f"Done — {len(index)} design proposals written to index.html")
PYEOF
