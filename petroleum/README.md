# Strategic Petroleum Reserve & Crude Benchmarks

A static dashboard tracking the U.S. Strategic Petroleum Reserve and world crude
benchmark prices. Self-contained: one HTML file, no build step, no server, no
dependencies beyond Chart.js from a CDN. Lives alongside the developments viewer
on the same GitHub Pages site and shares its palette, but shares no code with it.

Served at `/capitol-hill-developments/petroleum/`.

## Setting the API key

The page reads from the EIA open-data API **in the visitor's browser**, and EIA
requires a key on every request. [Register for a free one][reg] (about a minute,
arrives by email), then give it to the page one of three ways:

| How | Effect |
| --- | --- |
| `?key=YOUR_KEY` in the URL | Saved to local storage and stripped from the address bar, so it doesn't linger in history or in a link you share. |
| The **API key** button | Same thing, typed rather than pasted into a URL. |
| `EIA_API_KEY` in `index.html` | Baked in, so the page works for every visitor with no setup. |

The third option makes the key public the moment it is committed. EIA keys are
free, tied to an email and rate-limited per key, so publishing one is a normal
trade for a public dashboard — but it is a real choice, which is why the constant
ships empty and the page onboards visitors instead.

[reg]: https://www.eia.gov/opendata/register.php

## Why the browser fetches this directly

Baking the data into the page on a schedule — the pattern `refresh-market-data.sh`
uses for the developments viewer — would avoid the key entirely. Live fetching was
chosen instead, which constrains the sources to those that are both CORS-enabled
and reachable without a proxy. In practice that means EIA and very little else:
FRED's CSV endpoint sends no `Access-Control-Allow-Origin`, and JODI's world
database is a download behind a terms page. If the key ever becomes a nuisance,
moving to a baked constant plus a weekly workflow step is a contained change —
`loadAll()` is the only thing that would have to be replaced.

Responses are cached in local storage for six hours, so ordinary reloads cost no
API calls. **Refresh** clears the cache and re-fetches.

## The series registry

Every series the page requests is declared in one object, `SERIES`, near the top
of the script. Each panel names the series it needs and degrades on its own if
that series is missing — a failure costs one card and one row in the **Data
Sources** table at the bottom of the page, not the whole dashboard.

| Series | What it is | Route |
| --- | --- | --- |
| `WCSSTUS1` | Crude oil stocks in the SPR, weekly | `petroleum/stoc/wstk` |
| `WCESTUS1` | Commercial crude stocks excluding SPR, weekly | `petroleum/stoc/wstk` |
| `WCRNTUS2` | Net crude oil imports, weekly | `petroleum/move/wkly` |
| `RWTC` | WTI Cushing spot price, daily | `petroleum/pri/spt` |
| `RBRTE` | Europe Brent spot price, daily | `petroleum/pri/spt` |

**These IDs have not been checked against the live API.** The sandbox this was
built in has no route to `api.eia.gov`, so the code was written from EIA's
documented series naming and verified against a stub. They are conventional
identifiers and the stock and price ones are very likely right, but the first
person to open the page with a real key should glance at the Data Sources table:
anything showing `failed` or `no rows` needs its ID or route corrected in
`SERIES`, and nothing else has to change.

## Known gaps

- **Other countries' reserves.** The dashboard covers the U.S. only. Japan, Korea,
  Germany, Spain, India and China all hold public stocks, and the natural source
  for a multi-country view is either JODI's world oil database (monthly closing
  stocks, ~75 reporting countries) or the IEA's days-of-net-import-cover tables.
  Neither is browser-fetchable: JODI is a CSV download behind a terms page with no
  CORS header, and the IEA publishes to PDF and XLS. Both are perfectly fetchable
  from a GitHub Actions runner, so a country layer means adopting the baked-data
  pattern for that section — a refresh script plus a step in the weekly workflow.
- **Dubai and the OPEC basket.** EIA carries Brent and WTI but not the Asian
  benchmark or the OPEC reference basket, so "world prices" here means the
  Atlantic pair and the spread between them. IMF publishes Dubai monthly via FRED,
  which again needs the baked-data route.
- **SPR sweet vs. sour split.** Not in EIA's weekly series. DOE's Office of
  Petroleum Reserves publishes the inventory by crude type monthly, outside the
  API.

## Tests

```
node smoke-test.mjs        # from this folder; add KEEP_OPEN=1 to leave the browser up
```

Drives the real page in Chromium against a stubbed `api.eia.gov`, using synthetic
series shaped like the real ones — the 1980s fill, the plateau, the 2022 drawdown,
the refill. It covers paging past EIA's 5,000-row cap, each derived statistic
against an independently computed expectation, chart construction, the range and
theme controls, caching, and the four failure paths: no key, a rejected key, one
optional series down, and everything down. 54 checks; exit 0 means they passed,
exit 2 means Playwright is not installed and nothing ran.

Testing against the stub rather than the live API is deliberate: the only thing
that can break here is browser-side logic, and pointing the suite at EIA would
make it fail on their outages and rate limits instead of on ours. The one thing
the stub cannot confirm is whether the series IDs above are real — see the note
under the registry.
