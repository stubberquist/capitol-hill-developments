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
import sys, re, json, time, math, urllib.request, urllib.parse, concurrent.futures as cf

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
            return max(hits, key=lambda d: str(d.get("documentDate") or ""))
    return None

def fetch_docs(recs):
    """{record: [documents]} for every record; failures listed separately."""
    out, failed = {}, []
    def one(i):
        try:
            # 20 s, not the default 60: a lookup normally answers in under a second, and three
            # tries at 60 s across 2,485 records is hours if the library accepts and never replies.
            d = get_json(API + urllib.parse.quote(i, safe=""), timeout=20)
            return i, d if isinstance(d, list) else [], None
        except Exception as e:
            return i, None, str(e)
    with cf.ThreadPoolExecutor(6) as ex:
        for n, (i, d, err) in enumerate(ex.map(one, recs), 1):
            if err: failed.append(i)
            else: out[i] = d
            # Fail fast when the library is plainly down, rather than retrying every record
            # before the 5% rule below gets a look. Checked from the 50th result so a library
            # that hangs (72 s per record across three tries) is called in ~10 minutes, inside
            # the workflow's 30-minute limit.
            if n in (50, 100, 150, 200) and len(failed) > n * 0.2:
                ex.shutdown(wait=False, cancel_futures=True)
                sys.exit(f"ERROR: {len(failed)} of the first {n} lookups failed — the document library looks down; not replacing the index")
    return out, failed

t0 = time.time()
docs, failed = fetch_docs(ids)
print(f"looked up {len(ids)} land-use records in {time.time() - t0:.0f}s, {len(failed)} failed")
# A library outage mid-run would otherwise bake a half-empty index and silently strip the
# link from hundreds of cards. Fail loudly instead; last week's index stays in place.
if len(failed) > len(ids) * 0.05:
    sys.exit(f"ERROR: {len(failed)} of {len(ids)} lookups failed — not replacing the index")

# ── Linked records ─────────────────────────────────────────────────────────────
# Design review usually starts on its own Early Design Guidance record (NNNNNNN-EG) before
# the land-use application exists, and that stage's packet is filed there, not on the -LU
# record our permits point to. Nothing in the open data links the two (the -EG record can
# even carry a different address on the same block), so packets on -EG records were missed:
# 47 of the 376 active design-review projects that link our records (2026-11-19).
# Three exact signals, tested against Shaping Seattle's own record lists (2026-11-19):
#   1. Shaping Seattle's project pages list every record in an ACTIVE design-review
#      project — exact, but finished projects drop off the map.
#   2. An -EG with the same project number within 60 m.
#   3. An -EG number written in the land-use record's own file names (EDG reports are
#      often named "3036118-LU 3036562-EG …"), within 60 m: 75 right, 3 that also named
#      the paired building's -EG of the same development.
# A location-and-number guess without one of these picked the wrong project about 1 time in
# 6 where it would have mattered, so it is deliberately not used.
def soql(q, timeout=120):
    return get_json("https://data.seattle.gov/resource/ht3q-kdvx.json?" + urllib.parse.urlencode(q), timeout=timeout)

loc = {}
for k in range(0, len(ids), 300):
    lst = ",".join("'" + i.replace("'", "''") + "'" for i in ids[k:k + 300])
    for r in soql({"$select": "permitnum,latitude,longitude", "$where": f"permitnum in ({lst}) AND latitude IS NOT NULL", "$limit": "5000"}):
        loc[r["permitnum"]] = (float(r["latitude"]), float(r["longitude"]))
eg_loc = {r["permitnum"]: (float(r["latitude"]), float(r["longitude"]))
          for r in soql({"$select": "permitnum,latitude,longitude", "$where": "permitnum like '%-EG' AND latitude IS NOT NULL", "$limit": "50000"})}
if len(eg_loc) < 2000:
    sys.exit(f"ERROR: only {len(eg_loc)} -EG records from Socrata — refusing to continue")

def near(a, b, metres=60):
    if not a or not b: return False
    return math.hypot((a[0] - b[0]) * 111000, (a[1] - b[1]) * 111000 * math.cos(math.radians(47.6))) <= metres

linked = {i: set() for i in ids}
EG_NAME = re.compile(r"(?<!\d)(30\d{5})[-_ ]?EG\b|\bEG[-_ #]*(30\d{5})(?!\d)")
n_same = n_named = 0
for i in ids:
    here = loc.get(i)
    same = i[:-3] + "-EG"
    if i.endswith("-LU") and same in eg_loc and near(here, eg_loc[same]):
        linked[i].add(same); n_same += 1
    for d in docs.get(i, []):
        txt = " ".join(str(d.get(k) or "") for k in ("originalName", "referenceKey1", "referenceKey2", "referenceKey3", "documentDescription"))
        for m in EG_NAME.finditer(txt):
            e = (m.group(1) or m.group(2)) + "-EG"
            if e in eg_loc and near(here, eg_loc[e]) and e not in linked[i]:
                linked[i].add(e); n_named += 1

# Shaping Seattle: supplementary, so a failure here warns and carries on with the rest.
n_ss = 0
try:
    req = urllib.request.Request("https://web.seattle.gov/SDCI/ShapingSeattle/buildings/MapDots?filter=DR",
                                 data=b"", method="POST", headers={**UA, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        dots = json.load(r).get("Results") or []
    keys = [d["UniqueKey"] for d in dots if d.get("UniqueKey")]
    if len(keys) < 200:
        raise RuntimeError(f"only {len(keys)} design-review projects on the map")
    def page(k):
        u = "https://web.seattle.gov/SDCI/ShapingSeattle/buildings/Details?modal=true&id=" + urllib.parse.quote(k, safe="")
        for t in range(3):
            try:
                with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=30) as r:
                    return k, set(re.findall(r'/dpd/edms/\?ref=([0-9A-Za-z-]+)', r.read().decode("utf-8", "replace")))
            except Exception:
                time.sleep(2 * (t + 1))
        return k, None
    with cf.ThreadPoolExecutor(4) as ex:
        pages = list(ex.map(page, keys))
    if sum(v is None for _, v in pages) > len(keys) * 0.1:
        raise RuntimeError("over 10% of project pages failed")
    for k, recs in pages:
        recs = (recs or set()) | {k}
        group = {r for r in recs if re.fullmatch(r"\d{7}-(LU|EG)", r)}
        for r in group & set(ids):
            new = group - {r} - linked[r]
            if new: linked[r] |= new; n_ss += 1
    print(f"Shaping Seattle: {len(keys)} active projects read")
except Exception as e:
    print(f"::warning::Shaping Seattle project pages unavailable ({e}) — linking -EG records by number and file names only")

extra = sorted({r for v in linked.values() for r in v} - set(docs))
more, failed2 = fetch_docs(extra)
docs.update(more)
# Same rule as the first batch: 70 packets exist only on these records (2026-11-19), and losing
# the batch would drop their links with nothing but a log line.
if len(failed2) > len(extra) * 0.05:
    sys.exit(f"ERROR: {len(failed2)} of {len(extra)} linked-record lookups failed — not replacing the index")
print(f"linked records: {n_same} same-number -EG, {n_named} named in files, {n_ss} land-use records linked via Shaping Seattle; "
      f"{len(extra)} extra records looked up, {len(failed2)} failed")

index, from_linked = {}, 0
for i in ids:
    best = pick(docs.get(i, []))
    if best is None:
        alt = [d for r in sorted(linked[i]) for d in docs.get(r, [])]
        best = pick(alt)
        if best is not None: from_linked += 1
    if best is not None:
        # Size in whole MB (0 = under 1 MB) so the page can label the download before the click:
        # the city's server sends no length and packets run to 70 MB.
        size = int(best.get("documentFileSize") or 0)
        index[i] = (int(best["id"]), round(size / 1e6) if size > 0 else "")
print(f"{len(index)} land-use records with a proposal ({from_linked} found only on a linked record)")
if len(index) < 400:
    sys.exit(f"ERROR: only {len(index)} proposals found — refusing to embed a suspiciously small index")

# Packed as "gap:docId:MB,…" over the sorted numeric project numbers (every key is NNNNNNN-LU;
# MB is empty when the library gave no size). Delta-packed because it matters against the size budget.
# Unpacked once at load by the DR_INDEX initializer in index.html.
nums = sorted((int(k[:-3]), v) for k, v in index.items() if re.fullmatch(r"\d+-LU", k))
packed, prev = [], 0
for k, v in nums:
    packed.append(f"{k - prev}:{v[0]}:{v[1]}")
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
