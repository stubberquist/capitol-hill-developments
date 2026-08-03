#!/usr/bin/env bash
# Confirms GitHub Pages is actually serving the index.html we just pushed.
#
# Why this exists: on 2026-07-28 a push succeeded, the pages-build-deployment workflow then
# failed on a transient OIDC timeout, and the live site quietly kept serving the previous
# build. Nothing surfaced it — the push looked clean. Worse, re-running a failed deploy
# overwrites its conclusion, so the outage left no trace in run history. Workflow status is
# therefore not trustworthy on its own; this checks the thing that actually matters.
#
# Pages serves index.html byte-for-byte (no Jekyll front matter in it), so comparing a
# SHA-256 of the local file against the served one is exact and needs no build marker.
#
# Usage:  bash verify-deploy.sh [path-to-index.html] [url]
# Exits 0 once the served copy matches, 1 on timeout.

set -eo pipefail

FILE="${1:-$(cd "$(dirname "$0")" && pwd)/index.html}"
URL="${2:-https://stubberquist.github.io/capitol-hill-developments/}"
TIMEOUT=300     # Pages usually publishes in well under a minute; 5 min is the give-up point
INTERVAL=10

want=$(shasum -a 256 "$FILE" | cut -d' ' -f1)
echo "Waiting for $URL to serve the local build (sha256 ${want:0:12}…)"

deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  # A failed fetch shouldn't kill the loop — Pages can 404 briefly mid-publish
  got=$(curl -sf "$URL" 2>/dev/null | shasum -a 256 | cut -d' ' -f1) || got=""
  if [ "$got" = "$want" ]; then
    echo "OK — live site is serving this build."
    exit 0
  fi
  sleep "$INTERVAL"
done

echo "FAILED — after ${TIMEOUT}s the live site is still not serving this build." >&2
echo "  expected sha256: $want" >&2
echo "  served sha256:   ${got:-<fetch failed>}" >&2
echo "Check the pages-build-deployment run; a re-run may be needed." >&2
exit 1
