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
// Exits 0 when clean, 1 when something needs attention, so a cron or CI job can gate on it.
//
//   node health-check.mjs [url]
//
// Requires Google Chrome and Node 22+ (uses the built-in WebSocket).

import { spawn } from "child_process";

const URL_ = process.argv[2] || "https://stubberquist.github.io/capitol-hill-developments/";
const PORT = 9222 + Math.floor(process.uptime() * 1000) % 500;
const CHROME = process.env.CHROME_PATH
  || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

// Anything the page is expected to have once it has settled. A zero here means a data
// source went away even if nothing threw.
const EXPECT = {
  permits: 5000,       // Seattle Socrata
  nonMhaZones: 500,    // live zoning layer
  pendingRezones: 500, // proposed rezone layer
  cards: 1,            // grid actually rendered
};

function launch() {
  const proc = spawn(CHROME, [
    "--headless", "--disable-gpu", "--no-sandbox",
    `--remote-debugging-port=${PORT}`, "--window-size=1400,1000",
    `--user-data-dir=/tmp/chd-health-${PORT}`, "about:blank",
  ], { stdio: ["ignore", "pipe", "pipe"] });
  return proc;
}

async function attach() {
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
      if (r.ok) break;
    } catch {}
    await new Promise(r => setTimeout(r, 100));
  }
  const targets = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
  const page = targets.find(t => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let id = 0;
  const pending = new Map(), listeners = [];
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const { res, rej } = pending.get(m.id); pending.delete(m.id);
      m.error ? rej(new Error(m.error.message)) : res(m.result);
    } else if (m.method) listeners.forEach(f => f(m));
  };
  return {
    send: (method, params = {}) => new Promise((res, rej) => {
      const i = ++id; pending.set(i, { res, rej });
      ws.send(JSON.stringify({ id: i, method, params }));
    }),
    on: f => listeners.push(f),
    close: () => ws.close(),
  };
}

const proc = launch();
let cdp;
try {
  cdp = await attach();
} catch (e) {
  console.error("could not start Chrome:", e.message);
  proc.kill(); process.exit(1);
}

await cdp.send("Page.enable");
await cdp.send("Runtime.enable");
await cdp.send("Network.enable");
await cdp.send("Log.enable");
await cdp.send("Network.setCacheDisabled", { cacheDisabled: true });

const consoleErrors = [], exceptions = [], netFailures = [];
cdp.on(m => {
  const p = m.params;
  if (m.method === "Log.entryAdded" && p.entry.level === "error") consoleErrors.push(p.entry.text);
  if (m.method === "Runtime.exceptionThrown")
    exceptions.push(p.exceptionDetails.exception?.description || p.exceptionDetails.text);
  if (m.method === "Network.loadingFailed")
    netFailures.push(`${p.type}: ${p.errorText || p.blockedReason || "failed"}`);
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
    ytdUnits: document.querySelector("#an-stats .an-stat .value")?.textContent || null })`).catch(() => null);
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

cdp.close(); proc.kill();

const uniq = a => [...new Set(a)];
const problems = [];
if (!interactive) problems.push("page never became interactive (no permits or no cards rendered)");
if (data) {
  for (const [k, min] of Object.entries(EXPECT))
    if ((data[k] ?? 0) < min) problems.push(`${k} = ${data[k]} (expected >= ${min})`);
  if (data.duplicatePermitNums > 0) problems.push(`${data.duplicatePermitNums} duplicate permit numbers`);
}
if (analyticsState?.unavailable) problems.push("analytics reports Chart.js unavailable");
if (uniq(consoleErrors).length) problems.push(`${uniq(consoleErrors).length} console error(s)`);
if (uniq(exceptions).length) problems.push(`${uniq(exceptions).length} uncaught exception(s)`);
if (uniq(netFailures).length) problems.push(`${uniq(netFailures).length} failed request(s)`);

console.log(JSON.stringify({
  url: URL_,
  checkedAt: new Date().toISOString(),
  timeToInteractiveMs: interactive,
  data, map: mapState, analytics: analyticsState,
  consoleErrors: uniq(consoleErrors).slice(0, 10),
  uncaughtExceptions: uniq(exceptions).slice(0, 10),
  networkFailures: uniq(netFailures).slice(0, 10),
  problems,
}, null, 1));

if (problems.length) { console.log(`\nATTENTION — ${problems.length} problem(s):\n  ` + problems.join("\n  ")); process.exit(1); }
console.log("\nCLEAN — no console errors, no exceptions, no failed requests, all data sources populated.");
