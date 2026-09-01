#!/usr/bin/env node
// Daily health check for the live site.
//
// Loads the deployed page in headless Chrome over the DevTools Protocol and reports
// anything actually broken: console errors, uncaught exceptions, failed requests, dead
// data sources, and the load timings.
//
// It reads the real console (Log.entryAdded) on purpose. An earlier version of this check
// only hooked window.onerror and fetch failures, and so reported a clean "errors: []" for
// weeks while a Content-Security-Policy rule blocked the PWA icon on every single load —
// CSP violations are reported to the console, not raised as script errors.
//
// EXIT CODES — deliberately distinct, because a cron that cannot tell them apart is worse
// than no cron. Conflating them once meant a MODULE_NOT_FOUND (wrong working directory)
// looked exactly like a dead site.
//   0  clean
//   1  the SITE has a problem — investigate the app
//   2  the CHECK could not run — investigate the checker, the site is unknown
//
//   node health-check.mjs [url]
//
// Requires Google Chrome and Node 22+ (uses the built-in WebSocket).

import { spawn } from "child_process";
import { readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const URL_ = process.argv[2] || "https://stubberquist.github.io/capitol-hill-developments/";
const CHROME = process.env.CHROME_PATH
  || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
// Whole run must finish inside this. Without it a hung CDP call blocks forever: cdp.send
// never rejects, so `node health-check.mjs "gopher://nope/"` sat silently until killed and
// left six Chrome processes behind. In CI that burns the entire job timeout and reports
// nothing at all.
const RUN_BUDGET_MS = 180_000;

// Anything the page is expected to have once it has settled. A zero here means a data
// source went away even if nothing threw.
const EXPECT = {
  permits: 5000,        // Seattle Socrata
  nonMhaZones: 500,     // live zoning layer
  pendingRezones: 500,  // proposed rezone layer
  cards: 1,             // grid actually rendered
  // Street activity is fetched fire-and-forget with errors swallowed, so a permanently
  // broken SDOT feed would otherwise report CLEAN forever. It sits around 270.
  streetActivity: 100,
};

// Everything that needs tearing down, whatever way we exit.
let chrome = null;
let profileDir = null;

function cleanup() {
  try { chrome?.kill("SIGKILL"); } catch {}
  try { if (profileDir) rmSync(profileDir, { recursive: true, force: true }); } catch {}
}
process.on("exit", cleanup);
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { cleanup(); process.exit(2); });

const watchdog = setTimeout(() => {
  console.error(`health-check: exceeded ${RUN_BUDGET_MS}ms budget — treating as CHECK FAILURE`);
  cleanup();
  process.exit(2);
}, RUN_BUDGET_MS);
watchdog.unref();

function launch() {
  // Port 0 lets Chrome pick a free one and write it to DevToolsActivePort. The old scheme
  // was `9222 + Math.floor(process.uptime() * 1000) % 500`, which reads as 9222-9721 but
  // binds tighter than it looks: `%` beats `+`, and uptime at module load is 6-40ms, so five
  // consecutive runs produced 9228, 9229, 9230, 9230, 9232. Two concurrent runs collided,
  // and the loser's attach() then silently drove the winner's browser.
  profileDir = join(tmpdir(), `chd-health-${process.pid}-${Date.now()}`);
  chrome = spawn(CHROME, [
    "--headless", "--disable-gpu", "--no-sandbox",
    "--remote-debugging-port=0", "--window-size=1400,1000",
    `--user-data-dir=${profileDir}`, "about:blank",
  ], { stdio: ["ignore", "pipe", "pipe"] });
  return chrome;
}

// Chrome writes the port it actually bound here once it is listening.
async function resolvePort() {
  const portFile = join(profileDir, "DevToolsActivePort");
  for (let i = 0; i < 150; i++) {
    try {
      const first = readFileSync(portFile, "utf8").split("\n")[0].trim();
      if (first) return Number(first);
    } catch {}
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error("Chrome never reported a debugging port");
}

// Per-call timeout on every CDP command. Without one a single unanswered message hangs the
// whole run silently, which is the failure mode the watchdog above exists to catch — but
// rejecting here means we get a named error instead of a mute timeout.
const CALL_TIMEOUT_MS = 30_000;

async function attach(port) {
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (r.ok) break;
    } catch {}
    await new Promise(r => setTimeout(r, 100));
  }
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find(t => t.type === "page");
  if (!page) throw new Error("no page target in Chrome");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let id = 0;
  const pending = new Map(), listeners = [];
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const { res, rej, timer } = pending.get(m.id); pending.delete(m.id);
      clearTimeout(timer);
      m.error ? rej(new Error(m.error.message)) : res(m.result);
    } else if (m.method) listeners.forEach(f => f(m));
  };
  return {
    send: (method, params = {}) => new Promise((res, rej) => {
      const i = ++id;
      const timer = setTimeout(() => {
        pending.delete(i);
        rej(new Error(`CDP timeout after ${CALL_TIMEOUT_MS}ms: ${method}`));
      }, CALL_TIMEOUT_MS);
      pending.set(i, { res, rej, timer });
      ws.send(JSON.stringify({ id: i, method, params }));
    }),
    on: f => listeners.push(f),
    close: () => { try { ws.close(); } catch {} },
  };
}

// Anything below this line that throws is a CHECK failure (exit 2), not a site failure —
// we never got far enough to judge the site. Site verdicts are computed at the very end.
let cdp;
try {
  launch();
  const port = await resolvePort();
  cdp = await attach(port);
} catch (e) {
  console.error("health-check: could not start or attach to Chrome —", e.message);
  process.exit(2);
}

await cdp.send("Page.enable");
await cdp.send("Runtime.enable");
await cdp.send("Network.enable");
await cdp.send("Log.enable");
await cdp.send("Network.setCacheDisabled", { cacheDisabled: true });

const consoleErrors = [], exceptions = [], netFailures = [];
// Basemap tiles are watched separately from everything else because they fail in a way
// nothing else here can see. In Aug 2026 CARTO began requiring an API key and started
// serving unauthenticated requests a real 200 OK PNG with "API KEY REQUIRED" watermarked
// across the image — no HTTP error, no console error, no failed request. This check
// reported CLEAN for days while the map was covered in watermarks, and a person had to
// notice. Anything that only breaks the pixels needs an assertion about the pixels.
const tileReqs = [];
cdp.on(m => {
  const p = m.params;
  if (m.method === "Log.entryAdded" && p.entry.level === "error") consoleErrors.push(p.entry.text);
  if (m.method === "Runtime.exceptionThrown")
    exceptions.push(p.exceptionDetails.exception?.description || p.exceptionDetails.text);
  if (m.method === "Network.loadingFailed")
    netFailures.push(`${p.type}: ${p.errorText || p.blockedReason || "failed"}`);
  if (m.method === "Network.requestWillBeSent" && p.request.url.includes("basemaps.cartocdn.com"))
    tileReqs.push({ url: p.request.url, id: p.requestId, status: null });
  if (m.method === "Network.responseReceived" && p.response.url.includes("basemaps.cartocdn.com")) {
    const r = tileReqs.find(t => t.id === p.requestId);
    if (r) r.status = p.response.status;
  }
});

const evaluate = async expr => {
  const r = await cdp.send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || "eval failed");
  return r.result.value;
};

const t0 = Date.now();
await cdp.send("Page.navigate", { url: URL_ });
let interactive = null;
for (let i = 0; i < 900; i++) {
  await new Promise(r => setTimeout(r, 100));
  const ok = await evaluate(
    `(typeof allPermits!=="undefined" && allPermits && allPermits.length>0 && document.querySelectorAll(".card").length>0)`
  ).catch(() => false);
  if (ok) { interactive = Date.now() - t0; break; }
}

// Exercise map and analytics too — a grid-only check misses most of the app.
let mapState = null, analyticsState = null;
if (interactive) {
  await evaluate(`(()=>{setView("map");return true})()`).catch(() => {});
  for (let i = 0; i < 60; i++) {
    await new Promise(r => setTimeout(r, 200));
    if (await evaluate(`(typeof map!=="undefined"&&!!map&&markers.length>0)`).catch(() => false)) break;
  }
  await new Promise(r => setTimeout(r, 2500));
  mapState = await evaluate(`({ markers: markers.length,
    sites: new Set(getFilteredList().filter(p=>p.latitude&&p.longitude).map(p=>p.latitude+","+p.longitude)).size })`).catch(() => null);

  await evaluate(`(()=>{setView("analytics");return true})()`).catch(() => {});
  await new Promise(r => setTimeout(r, 9000));
  analyticsState = await evaluate(`({ charts: Object.keys(anCharts).length,
    unavailable: (document.getElementById("an-stats")?.textContent||"").includes("Charts unavailable"),
    // .num, not .value — renderAnalytics emits <span class="num">. The old selector matched
    // nothing and reported null on every run since it shipped.
    ytdUnits: document.querySelector("#an-stats .an-stat .num")?.textContent || null })`).catch(() => null);
}

const data = interactive ? await evaluate(`({
  permits: allPermits.length,
  duplicatePermitNums: allPermits.length - new Set(allPermits.map(p=>p.permitnum)).size,
  nonMhaZones: (typeof nonMhaZones!=="undefined" && nonMhaZones) ? nonMhaZones.length : 0,
  pendingRezones: (typeof pendingRezones!=="undefined" && pendingRezones) ? pendingRezones.length : 0,
  streetActivity: typeof STREET_ACTIVITY!=="undefined" ? Object.keys(STREET_ACTIVITY).length : 0,
  cards: document.querySelectorAll(".card").length,
  sipFetched: typeof SIP_FETCHED!=="undefined" ? SIP_FETCHED : null,
  rezoneFetched: typeof REZONE_FETCHED!=="undefined" ? REZONE_FETCHED : null,
})`).catch(() => null) : null;

// Read the key out of the DEPLOYED page rather than hardcoding it here — one source of
// truth, and it means this also catches the key being removed or mangled in a refresh.
const cartoKey = await evaluate(`typeof CARTO_KEY !== "undefined" ? CARTO_KEY : null`).catch(() => null);

cdp.close();
cleanup();

// ── Basemap tile check ───────────────────────────────────────────────────────
// Deliberately NOT an absolute byte-size band: keyed tiles measured 2,349-5,787 bytes
// across four tiles at different zooms, so any fixed threshold would either miss the
// watermark or fire on a legitimately busy tile. Instead compare the same tile fetched
// with and without the key. CARTO serves different bytes to authenticated and
// unauthenticated callers, so identical responses mean our key is not being honoured —
// which is exactly the state that produced watermarked tiles.
const TILE_PROBE = "https://a.basemaps.cartocdn.com/dark_all/12/655/1425.png";
let basemap = { keyPresent: !!cartoKey, checked: false };
try {
  const sha = async (url) => {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const buf = Buffer.from(await res.arrayBuffer());
    const { createHash } = await import("crypto");
    return { hash: createHash("sha256").update(buf).digest("hex").slice(0, 16), bytes: buf.length,
             // Full 4-byte signature. This checked bytes 1-3 ("PNG") but not byte 0 (0x89),
             // so a body that happened to carry those three characters would pass.
             isPng: buf.length > 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47 };
  };
  const keyed = cartoKey ? await sha(`${TILE_PROBE}?key=${cartoKey}`) : null;
  const unkeyed = await sha(TILE_PROBE);
  basemap = {
    keyPresent: !!cartoKey, checked: true,
    keyedBytes: keyed?.bytes ?? null, unkeyedBytes: unkeyed.bytes,
    keyedIsPng: keyed?.isPng ?? null,
    // Differing responses = the key is doing something = we are not being watermarked.
    keyHonoured: keyed ? keyed.hash !== unkeyed.hash : false,
  };
} catch (e) {
  basemap = { keyPresent: !!cartoKey, checked: false, error: e.message };
}

const uniq = a => [...new Set(a)];
const problems = [];
if (!interactive) problems.push("page never became interactive (no permits or no cards rendered)");
if (data) {
  for (const [k, min] of Object.entries(EXPECT))
    if ((data[k] ?? 0) < min) problems.push(`${k} = ${data[k]} (expected >= ${min})`);
  if (data.duplicatePermitNums > 0) problems.push(`${data.duplicatePermitNums} duplicate permit numbers`);
}
if (analyticsState?.unavailable) problems.push("analytics reports Chart.js unavailable");

// Basemap. Each of these fails silently in the browser, so they have to be asserted here.
// An exception in the probe used to vanish: this section only fed `problems` when
// `checked === true`, and `basemap.error` was written into the output JSON but never
// asserted on. A probe that threw — CDN edge refusing a bare Node fetch, a DNS blip, CARTO
// switching from watermarking to hard-rejecting — silently downgraded to "not checked" and
// the run still printed CLEAN. That is precisely the failure this whole check exists to
// prevent, one level removed: reporting healthy while the assertion never actually ran.
if (!basemap.checked)
  problems.push(`basemap probe could not run (${basemap.error || "unknown"}) — tile watermarking unverified`);
if (!basemap.keyPresent) problems.push("CARTO_KEY missing from the deployed page — basemap tiles will be watermarked");
else if (basemap.checked && !basemap.keyHonoured)
  problems.push("CARTO key is not changing the tile response — tiles are likely watermarked (or CARTO changed enforcement)");
if (basemap.checked && basemap.keyedIsPng === false) problems.push("CARTO returned a non-PNG for a keyed tile request");
if (interactive) {
  if (!tileReqs.length) problems.push("map view requested no basemap tiles at all");
  else {
    const unkeyedReqs = tileReqs.filter(t => !t.url.includes("key="));
    const badStatus = tileReqs.filter(t => t.status !== null && t.status !== 200);
    if (unkeyedReqs.length) problems.push(`${unkeyedReqs.length} basemap tile request(s) sent without an API key`);
    if (badStatus.length) problems.push(`${badStatus.length} basemap tile request(s) returned non-200`);
  }
}

if (uniq(consoleErrors).length) problems.push(`${uniq(consoleErrors).length} console error(s)`);
if (uniq(exceptions).length) problems.push(`${uniq(exceptions).length} uncaught exception(s)`);
if (uniq(netFailures).length) problems.push(`${uniq(netFailures).length} failed request(s)`);

console.log(JSON.stringify({
  url: URL_,
  checkedAt: new Date().toISOString(),
  timeToInteractiveMs: interactive,
  data, map: mapState, analytics: analyticsState,
  basemap: { ...basemap, tileRequests: tileReqs.length,
             tilesKeyed: tileReqs.filter(t => t.url.includes("key=")).length },
  consoleErrors: uniq(consoleErrors).slice(0, 10),
  uncaughtExceptions: uniq(exceptions).slice(0, 10),
  networkFailures: uniq(netFailures).slice(0, 10),
  problems,
}, null, 1));

clearTimeout(watchdog);

// Note on the split: a page that loads but never populates is a SITE problem (exit 1) — the
// checker did its job and found the site wanting. Exit 2 is reserved for cases where we
// never got far enough to have an opinion at all: Chrome wouldn't start, CDP timed out, the
// watchdog fired. Those are handled above, before any site assertion runs.
if (problems.length) { console.log(`\nATTENTION — ${problems.length} problem(s):\n  ` + problems.join("\n  ")); process.exit(1); }
console.log("\nCLEAN — no console errors, no exceptions, no failed requests, all data sources populated.");
