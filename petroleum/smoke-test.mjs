#!/usr/bin/env node
// Drives petroleum/index.html in Chromium against a stubbed api.eia.gov.
//
// Why a stub rather than the real API: this page has no build step and no server,
// so the only thing that can go wrong is the browser-side logic — paging, series
// alignment, the derived statistics, and how it behaves when a series or the key
// is bad. All of that is testable without a key, and testing it against live EIA
// would make the suite fail on their outages and rate limits instead of on ours.
//
//   node petroleum/smoke-test.mjs            # headless, prints a pass/fail report
//   KEEP_OPEN=1 node petroleum/smoke-test.mjs # leaves the browser open to look at
//
// Exit 0 = pass, 1 = a check failed, 2 = the harness itself could not run.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, extname } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));

// Resolved from a local devDependency if there is one, otherwise from a global
// install — CI images and dev machines disagree about where Playwright lives, and
// a skipped test because of that would be indistinguishable from a passing one.
async function loadPlaywright() {
  try { return await import("playwright"); } catch {}
  try {
    const { execSync } = await import("node:child_process");
    const { pathToFileURL } = await import("node:url");
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    return await import(pathToFileURL(join(root, "playwright", "index.js")).href);
  } catch {}
  return null;
}

const playwright = await loadPlaywright();
if (!playwright) {
  console.error("Playwright is not installed — `npm i -D playwright` to run this. Skipping.");
  process.exit(2);
}
// A CommonJS Playwright reached through import() lands under `default`.
const chromium = playwright.chromium || (playwright.default && playwright.default.chromium);
if (!chromium) {
  console.error("Playwright loaded but exposes no chromium launcher. Skipping.");
  process.exit(2);
}

// ── Synthetic EIA series ──────────────────────────────────────────────────────
// Shaped like the real thing (weekly Friday readings in thousand barrels, a fill
// through the 80s, a plateau, the 2022 drawdown, a slow refill) so the derived
// figures have something meaningful to be right or wrong about.
const MS_DAY = 86400000;

function fridays(fromISO, toISO) {
  const out = [];
  const d = new Date(fromISO + "T00:00:00Z");
  while (d.getUTCDay() !== 5) d.setUTCDate(d.getUTCDate() + 1);
  const end = Date.parse(toISO + "T00:00:00Z");
  while (d.getTime() <= end) { out.push(d.toISOString().slice(0, 10)); d.setUTCDate(d.getUTCDate() + 7); }
  return out;
}
function weekdays(fromISO, toISO) {
  const out = [];
  const d = new Date(fromISO + "T00:00:00Z");
  const end = Date.parse(toISO + "T00:00:00Z");
  while (d.getTime() <= end) {
    const dow = d.getUTCDay();
    if (dow !== 0 && dow !== 6) out.push(d.toISOString().slice(0, 10));
    d.setUTCDate(d.getUTCDate() + 1);
  }
  return out;
}

const TODAY = new Date(Date.now() - 5 * MS_DAY).toISOString().slice(0, 10);

const PROFILE = {
  peak:      { on: "2010-06-25", v: 726600 },
  plateau:   726600,
  preLevel:  593700,           // late-2021 level the refill is measured against
  trough:    { on: "2023-07-07", v: 346800 },
  refillPerWeek: 700,
};

function sprValue(iso) {
  const t = Date.parse(iso + "T00:00:00Z");
  const y = +iso.slice(0, 4);
  if (y < 2010) {                                   // fill years: ramp 108 → peak
    const f = (t - Date.parse("1982-01-01")) / (Date.parse(PROFILE.peak.on) - Date.parse("1982-01-01"));
    return Math.round(108000 + f * (PROFILE.peak.v - 108000));
  }
  if (iso < "2022-03-01") {                         // slow policy sales off the peak
    const f = (t - Date.parse(PROFILE.peak.on)) / (Date.parse("2022-03-01") - Date.parse(PROFILE.peak.on));
    return Math.round(PROFILE.peak.v + f * (PROFILE.preLevel - PROFILE.peak.v));
  }
  if (iso <= PROFILE.trough.on) {                   // the 2022 drawdown
    const f = (t - Date.parse("2022-03-01")) / (Date.parse(PROFILE.trough.on) - Date.parse("2022-03-01"));
    return Math.round(PROFILE.preLevel + f * (PROFILE.trough.v - PROFILE.preLevel));
  }
  const weeks = (t - Date.parse(PROFILE.trough.on + "T00:00:00Z")) / (7 * MS_DAY);
  return Math.round(PROFILE.trough.v + weeks * PROFILE.refillPerWeek);
}

// Price series with a couple of shocks in it, so the spread is not a flat line.
function priceValue(iso, base, amp, phase) {
  const t = Date.parse(iso + "T00:00:00Z") / MS_DAY;
  return Math.round((base + amp * Math.sin(t / 220 + phase) + 6 * Math.sin(t / 41)) * 100) / 100;
}

const WEEKS = fridays("1982-01-01", TODAY);
const DAYS  = weekdays("1987-05-20", TODAY);

const SERIES_DATA = {
  WCSSTUS1: WEEKS.map(t => ({ period: t, value: sprValue(t) })),
  WCESTUS1: WEEKS.map(t => ({ period: t, value: 420000 + Math.round(40000 * Math.sin(Date.parse(t) / MS_DAY / 58)) })),
  WCRNTUS2: fridays("1990-01-01", TODAY).map(t => ({ period: t, value: 2400 + Math.round(600 * Math.sin(Date.parse(t) / MS_DAY / 90)) })),
  RWTC:     DAYS.map(t => ({ period: t, value: priceValue(t, 62, 22, 0) })),
  RBRTE:    DAYS.map(t => ({ period: t, value: priceValue(t, 66, 22, 0.15) })),
};

// ── Static server ─────────────────────────────────────────────────────────────
// Served over http rather than opened as file://, because the page uses local
// storage for the key and the theme, which a file:// origin refuses.
const TYPES = { ".html": "text/html", ".mjs": "text/javascript", ".js": "text/javascript" };
const server = createServer(async (req, res) => {
  const path = req.url.split("?")[0] === "/" ? "/index.html" : req.url.split("?")[0];
  try {
    const body = await readFile(join(HERE, path.replace(/^\/+/, "")));
    res.writeHead(200, { "content-type": TYPES[extname(path)] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
});
await new Promise(r => server.listen(0, "127.0.0.1", r));
const ORIGIN = `http://127.0.0.1:${server.address().port}/`;

// ── Harness ───────────────────────────────────────────────────────────────────
const checks = [];
function check(name, ok, detail = "") {
  checks.push({ name, ok, detail });
  console.log(`${ok ? "  ok  " : "  FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
}
const near = (a, b, tol = 0.05) => Math.abs(a - b) <= tol;

const browser = await chromium.launch();

/** One page wired to a stubbed EIA. `opts.badKey` makes every request 403;
 *  `opts.failSeries` fails just those series IDs. */
async function newPage(opts = {}) {
  const ctx = await browser.newContext();
  const errors = [];
  const requests = [];

  // Chart.js comes from a CDN this sandbox cannot reach, and the page's SRI hash
  // means a stubbed body would be rejected anyway. Define the constructor before
  // any page script runs and let the CDN request fail: the page only ever checks
  // for window.Chart, so this exercises the real render path and hands the test
  // the configs it built.
  await ctx.addInitScript(() => {
    window.__charts = {};
    class FakeChart {
      constructor(el, cfg) { this.el = el; this.config = cfg; window.__charts[el.id] = cfg; }
      destroy() { delete window.__charts[this.el.id]; }
    }
    FakeChart.defaults = { font: {}, color: "", borderColor: "" };
    window.Chart = FakeChart;
  });
  await ctx.route("**/unpkg.com/**", r => r.abort());

  await ctx.route("**://api.eia.gov/**", async route => {
    const url = new URL(route.request().url());
    const q = url.searchParams;
    requests.push({ path: url.pathname, series: q.get("facets[series][]"), key: q.get("api_key"),
                    offset: +q.get("offset"), length: +q.get("length") });

    if (opts.badKey) {
      return route.fulfill({ status: 403, contentType: "application/json",
                             body: JSON.stringify({ error: "invalid or missing api_key", code: 403 }) });
    }
    const id = q.get("facets[series][]");
    if (opts.failSeries && opts.failSeries.includes(id)) {
      return route.fulfill({ status: 500, contentType: "application/json",
                             body: JSON.stringify({ error: "series temporarily unavailable" }) });
    }
    const all = (SERIES_DATA[id] || []).filter(r => !q.get("start") || r.period >= q.get("start"));
    const offset = +(q.get("offset") || 0), length = +(q.get("length") || 5000);
    return route.fulfill({
      status: 200, contentType: "application/json",
      body: JSON.stringify({ response: { total: all.length, dateFormat: "YYYY-MM-DD",
                                         frequency: q.get("frequency"),
                                         data: all.slice(offset, offset + length).map(r => ({ ...r, series: id })) } }),
    });
  });

  const page = await ctx.newPage();
  // Chromium logs every non-2xx response as a console error even when the page
  // handled it cleanly, and scenarios 2 and 3 provoke those deliberately. What
  // matters is whether the page's own code complained, so resource-load noise is
  // filtered and real script failures are collected from `pageerror`.
  page.on("console", m => {
    const t = m.text();
    if (m.type() === "error" && !/unpkg\.com|ERR_FAILED|Failed to load resource/.test(t)) errors.push(t);
  });
  page.on("pageerror", e => errors.push("pageerror: " + e.message));
  return { page, ctx, errors, requests };
}

const settled = page => page.waitForFunction(
  () => window.__dash && (window.__dash.data || !document.getElementById("setup").classList.contains("hidden")),
  null, { timeout: 20000 });

// ── 1. Happy path ─────────────────────────────────────────────────────────────
console.log("\n▸ Happy path (key supplied in the URL)");
{
  const { page, ctx, errors, requests } = await newPage();
  await page.goto(ORIGIN + "?key=TESTKEY123");
  await settled(page);

  check("the key is consumed and stripped from the address bar",
        !(await page.evaluate(() => location.search)).includes("key="),
        "search = " + JSON.stringify(await page.evaluate(() => location.search)));
  check("the key is kept for next visit",
        (await page.evaluate(() => localStorage.getItem("spr-dash.eia-key"))) === "TESTKEY123");

  const data = await page.evaluate(() => {
    const d = window.__dash.data;
    return {
      statuses: Object.fromEntries(Object.keys(d.stats ? window.__dash.SERIES : {}).map(k => [k, d[k].status])),
      counts: Object.fromEntries(Object.keys(window.__dash.SERIES).map(k => [k, d[k].rows.length])),
      stats: { current: d.stats.current, week: d.stats.weekChange, year: d.stats.yearChange,
               pctCap: d.stats.pctCapacity, peak: d.stats.peak, trough: d.stats.trough,
               preLevel: d.stats.preLevel, refilled: d.stats.refilled, pace: d.stats.pace,
               projection: d.stats.projection, cover: d.stats.cover },
      prices: d.pstats,
      coverLen: d.cover.length,
    };
  });

  check("every series loaded", Object.values(data.statuses).every(s => s === "ok"), JSON.stringify(data.statuses));
  check("weekly SPR paged in fully", data.counts.spr === SERIES_DATA.WCSSTUS1.length,
        `${data.counts.spr} rows vs ${SERIES_DATA.WCSSTUS1.length} served`);
  check("daily prices paged past the 5000-row cap", data.counts.wti === SERIES_DATA.RWTC.length,
        `${data.counts.wti} rows vs ${SERIES_DATA.RWTC.length} served`);
  check("paging actually made multiple requests",
        requests.filter(r => r.series === "RWTC").length === Math.ceil(SERIES_DATA.RWTC.length / 5000),
        requests.filter(r => r.series === "RWTC").length + " requests for RWTC");

  // Independently recomputed here rather than read back from the page.
  const raw = SERIES_DATA.WCSSTUS1;
  const cur = raw[raw.length - 1], prev = raw[raw.length - 2], yr = raw[raw.length - 53];
  check("current level matches the last reading", data.stats.current.v === cur.value && data.stats.current.t === cur.period);
  check("weekly change is last minus previous", data.stats.week === cur.value - prev.value);
  check("52-week change spans 52 readings", data.stats.year === cur.value - yr.value);
  check("percent of design capacity", near(data.stats.pctCap, (cur.value / 727000) * 100, 0.001));

  const peak = raw.reduce((a, r) => (r.value > a.value ? r : a));
  check("all-time peak is found in the data", data.stats.peak.v === peak.value && data.stats.peak.t === peak.period,
        `${data.stats.peak.t} @ ${data.stats.peak.v}`);
  const post = raw.filter(r => r.period >= "2022-01-01");
  const trough = post.reduce((a, r) => (r.value < a.value ? r : a));
  check("post-2022 trough is found", data.stats.trough.v === trough.value && data.stats.trough.t === trough.period,
        `${data.stats.trough.t} @ ${data.stats.trough.v}`);
  check("refilled-since-trough is current minus trough", data.stats.refilled === cur.value - trough.value);
  const pre = raw.filter(r => r.period >= "2021-01-01" && r.period < "2022-01-01").reduce((a, r) => (r.value > a.value ? r : a));
  check("pre-drawdown level comes from 2021", data.stats.preLevel.v === pre.value);
  check("refill pace is positive and matches the profile",
        near(data.stats.pace, PROFILE.refillPerWeek, 1), data.stats.pace + " thousand bbl/week");
  check("a restoration date is projected", typeof data.stats.projection === "string" && data.stats.projection.length > 0,
        String(data.stats.projection));

  const imports = SERIES_DATA.WCRNTUS2.slice(-4).reduce((s, r) => s + r.value, 0) / 4;
  check("days of cover ≈ SPR ÷ four-week average imports", near(data.stats.cover.v, cur.value / imports, 1.5),
        `${data.stats.cover.v.toFixed(1)} days`);
  check("cover series drops the pre-1990 weeks with no import data",
        data.coverLen > 0 && data.coverLen < data.counts.spr, `${data.coverLen} of ${data.counts.spr} weeks`);

  check("Brent and WTI latest quotes are read",
        data.prices.brent.v === SERIES_DATA.RBRTE.at(-1).value && data.prices.wti.v === SERIES_DATA.RWTC.at(-1).value);
  const bLast = SERIES_DATA.RBRTE.at(-1), wOnDay = SERIES_DATA.RWTC.find(r => r.period === bLast.period);
  check("spread is taken from a day both benchmarks priced",
        near(data.prices.spread, bLast.value - wOnDay.value, 0.001), `$${data.prices.spread.toFixed(2)} on ${data.prices.spreadOn}`);

  const built = await page.evaluate(() => Object.keys(window.__charts));
  const expected = ["chart-spr-history", "chart-spr-change", "chart-refill", "chart-spr-vs-comm",
                    "chart-cover", "chart-benchmarks", "chart-spread", "chart-spr-vs-wti"];
  check("all eight charts drew", expected.every(id => built.includes(id)),
        `built ${built.length}: ${expected.filter(e => !built.includes(e)).join(", ") || "none missing"}`);

  const pts = await page.evaluate(() => window.__charts["chart-benchmarks"].data.datasets.map(d => d.data.length));
  check("the benchmark chart is thinned to a drawable size", pts.every(n => n > 0 && n <= 901), "points: " + pts.join("/"));
  check("the refill chart carries a dashed pre-drawdown reference",
        await page.evaluate(() => !!window.__charts["chart-refill"].data.datasets[1].borderDash));
  check("the price overlay uses a second axis",
        await page.evaluate(() => window.__charts["chart-spr-vs-wti"].data.datasets[1].yAxisID === "y1"));
  check("the fill/draw chart colours bars individually",
        await page.evaluate(() => Array.isArray(window.__charts["chart-spr-change"].data.datasets[0].backgroundColor)));

  const tiles = await page.locator("#spr-stats .stat").count();
  const ptiles = await page.locator("#price-stats .stat").count();
  check("stat tiles rendered", tiles >= 7 && ptiles === 5, `${tiles} SPR tiles, ${ptiles} price tiles`);
  check("the header reports how current the data is",
        /SPR through/.test(await page.locator("#as-of").innerText()));
  check("every source row reports ok",
        (await page.locator("#source-rows .pill.ok").count()) === 5);

  // Range and theme both rebuild every chart; a stale canvas after either is a real bug.
  await page.click('[data-range="1"]');
  await page.waitForFunction(() => window.__dash.range === 1);
  const oneYear = await page.evaluate(() => window.__charts["chart-benchmarks"].data.labels.length);
  await page.click('[data-range="0"]');
  const maxRange = await page.evaluate(() => window.__charts["chart-benchmarks"].data.labels.length);
  check("the range selector actually narrows the series", oneYear < maxRange, `1Y=${oneYear} points, Max=${maxRange}`);

  const themeBefore = await page.evaluate(() => document.documentElement.dataset.theme || "dark");
  await page.click("#btn-theme");
  check("theme toggle repaints the charts",
        (await page.evaluate(() => Object.keys(window.__charts).length)) === expected.length);
  const themeAfter = await page.evaluate(() => localStorage.getItem("spr-dash.theme"));
  check("theme choice is remembered", themeAfter && themeAfter !== themeBefore, `${themeBefore} → ${themeAfter}`);

  check("no console errors", errors.length === 0, errors.slice(0, 3).join(" | "));
  if (!process.env.KEEP_OPEN) await ctx.close();
}

// ── 2. One optional series down ───────────────────────────────────────────────
console.log("\n▸ Degradation when an optional series fails");
{
  const { page, ctx, errors } = await newPage({ failSeries: ["WCRNTUS2"] });
  await page.goto(ORIGIN + "?key=TESTKEY123");
  await settled(page);

  check("the dashboard still renders", !(await page.locator("#dash").isHidden()));
  check("the SPR figures are unaffected",
        (await page.evaluate(() => window.__dash.data.stats.current.v)) === SERIES_DATA.WCSSTUS1.at(-1).value);
  check("the cover tile says n/a rather than a wrong number",
        /n\/a/.test(await page.locator("#spr-stats").innerText()));
  check("the cover card explains itself instead of drawing an empty chart",
        await page.locator("#msg-cover").isVisible() &&
        /net-import series/i.test(await page.locator("#msg-cover").innerText()));
  check("the failing series is named in Data Sources",
        (await page.locator("#source-rows .pill.bad").count()) === 1 &&
        /WCRNTUS2/.test(await page.locator("#source-rows").innerText()));
  check("the other seven charts still drew",
        (await page.evaluate(() => Object.keys(window.__charts).length)) === 7);
  check("no console errors", errors.length === 0, errors.slice(0, 3).join(" | "));
  await ctx.close();
}

// ── 3. Rejected key ───────────────────────────────────────────────────────────
console.log("\n▸ A key EIA rejects");
{
  const { page, ctx, errors } = await newPage({ badKey: true });
  await page.goto(ORIGIN + "?key=NOPE");
  await settled(page);

  check("the setup panel comes back", await page.locator("#setup").isVisible());
  check("it says the key was rejected, with EIA's reason",
        /rejected/i.test(await page.locator("#setup-title").innerText()) &&
        /api_key/i.test(await page.locator("#setup-msg").innerText()));
  check("the stale dashboard is hidden rather than left showing", await page.locator("#dash").isHidden());
  check("a way to forget the bad key is offered", await page.locator("#key-clear").isVisible());
  check("no console errors", errors.length === 0, errors.slice(0, 3).join(" | "));
  await ctx.close();
}

// ── 4. First visit with nothing in local storage ──────────────────────────────
//
// What should happen depends on how the page is deployed, so the expectation is
// read from the source rather than assumed: with EIA_API_KEY left empty a first
// visit must onboard, and with a key baked in it must just work. Both are valid
// configurations and the suite has to pass in either.
const bakedKey = (/const EIA_API_KEY = "([^"]*)"/.exec(await readFile(join(HERE, "index.html"), "utf8")) || [, ""])[1];
console.log(`\n▸ First visit, nothing stored (page ships ${bakedKey ? "WITH" : "without"} a baked-in key)`);
{
  const { page, ctx, errors, requests } = await newPage();
  await page.goto(ORIGIN);
  await settled(page);

  if (bakedKey) {
    check("the dashboard loads with no setup step", !(await page.locator("#dash").isHidden()));
    check("onboarding stays out of the way", await page.locator("#setup").isHidden());
    check("the baked-in key is the one sent to EIA",
          requests.length > 0 && requests.every(r => r.key === bakedKey));
  } else {
    check("onboarding is shown", await page.locator("#setup").isVisible());
    check("no pointless request is made without a key", requests.length === 0);
    check("the registration link points at EIA",
          (await page.locator("#setup a").getAttribute("href")).startsWith("https://www.eia.gov/opendata/register"));
  }

  // A pasted key must win over whatever the page shipped with, so a visitor who
  // brings their own is not silently sharing the published key's rate limit.
  if (bakedKey) await page.click("#btn-key");
  await page.fill("#key-input", "PASTED-KEY");
  await page.click("#key-save");
  await page.waitForFunction(() => window.__dash.data);
  const after = requests.filter(r => r.key === "PASTED-KEY");
  check("pasting a key loads the dashboard", !(await page.locator("#dash").isHidden()));
  check("a pasted key takes precedence over the baked-in one", after.length > 0,
        `${after.length} requests carried the pasted key`);
  check("no console errors", errors.length === 0, errors.slice(0, 3).join(" | "));
  await ctx.close();
}

// ── 5. Cache ──────────────────────────────────────────────────────────────────
console.log("\n▸ Caching across reloads");
{
  const { page, ctx, errors, requests } = await newPage();
  await page.goto(ORIGIN + "?key=TESTKEY123");
  await settled(page);
  const firstLoad = requests.length;

  await page.reload();
  await settled(page);
  check("a reload is served from cache, not re-fetched", requests.length === firstLoad,
        `${requests.length - firstLoad} extra requests`);
  check("the cached data renders identically",
        (await page.evaluate(() => window.__dash.data.stats.current.v)) === SERIES_DATA.WCSSTUS1.at(-1).value);

  await page.click("#btn-refresh");
  for (let i = 0; i < 100 && requests.length === firstLoad; i++) await page.waitForTimeout(50);
  await page.waitForFunction(() => !document.getElementById("btn-refresh").disabled);
  check("the refresh button bypasses the cache", requests.length > firstLoad,
        `${requests.length - firstLoad} fresh requests`);
  check("no console errors", errors.length === 0, errors.slice(0, 3).join(" | "));
  await ctx.close();
}

// ── Report ────────────────────────────────────────────────────────────────────
if (!process.env.KEEP_OPEN) { await browser.close(); server.close(); }
const failed = checks.filter(c => !c.ok);
console.log(`\n${checks.length - failed.length}/${checks.length} checks passed`);
if (failed.length) {
  console.log("Failed:\n" + failed.map(f => "  · " + f.name + (f.detail ? " — " + f.detail : "")).join("\n"));
  process.exit(1);
}
console.log("Dashboard logic is sound against the stubbed API.");
