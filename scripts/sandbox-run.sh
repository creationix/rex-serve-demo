#!/usr/bin/env bash
#
# sandbox-run.sh — run the standalone rex-serve server in a Vercel Sandbox and
# verify HTTP + WebSockets work through the public *.vercel.run ingress.
#
# Technique: build a fully static x86_64 musl binary on the host with Docker
# (via the repo Dockerfile), then upload just that binary + the project files to
# the sandbox and run it. The sandbox needs no Rust toolchain, no compiler, and
# no Docker — it just runs a ~10 MB self-contained binary, so it's serving in
# seconds. (rex-serve uses native `axum::serve`, so WebSocket upgrades work
# without `vercel_runtime`.)
#
# Prerequisites:
#   - Docker (with buildx) on the host
#   - Vercel CLI with `vercel sandbox` (logged in, project linked)
#   - Node 21+ locally (provides a global WebSocket for the test client)
#   - submodules checked out: git submodule update --init --recursive
#
# Usage:
#   scripts/sandbox-run.sh
#
# Env overrides:
#   TIMEOUT=<dur>   sandbox lifetime (default: 20m)
#   KEEP=1          leave the sandbox running on exit (for manual testing)
#
set -euo pipefail

TIMEOUT="${TIMEOUT:-20m}"
KEEP="${KEEP:-}"
PORT=3000
ID=""
SERVER_JOB=""

command -v docker >/dev/null || { echo "error: docker not found (needed to build the static binary)"; exit 1; }
command -v vercel >/dev/null || { echo "error: Vercel CLI not found (need 'vercel sandbox')"; exit 1; }
command -v node   >/dev/null || { echo "error: node not found (need Node 21+ for the WS test)"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

cleanup() {
  [ -n "$SERVER_JOB" ] && kill "$SERVER_JOB" 2>/dev/null || true
  [ -z "$ID" ] && return
  if [ -n "$KEEP" ]; then
    echo "KEEP=1 — leaving sandbox '$ID' running (remove with: vercel sandbox rm $ID)"
    return
  fi
  log "Removing sandbox '$ID'"
  vercel sandbox rm "$ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Building static x86_64 binary on the host (Docker, musl)"
# The Sandbox is linux/amd64; force that platform so the binary runs there even
# when the host is arm64. Extract the binary from the built image.
docker build --platform linux/amd64 -t rex-serve:musl .
BUILD_DIR="$(mktemp -d)"
CID="$(docker create --platform linux/amd64 rex-serve:musl)"
docker cp "$CID":/usr/local/bin/rex-serve "$BUILD_DIR/rex-serve"
docker rm "$CID" >/dev/null
echo "binary: $(cd "$BUILD_DIR" && du -h rex-serve | cut -f1)"

log "Bundling binary + project files"
cp -R routes "$BUILD_DIR/"
cp rex-serve.toml rex-serve.rexd "$BUILD_DIR/"
BUNDLE="$(mktemp -u).tgz"
tar czf "$BUNDLE" -C "$BUILD_DIR" .

log "Creating sandbox (port $PORT, timeout $TIMEOUT)"
# The CLI emits the machine identifier on stdout; the decorative box + the URL go
# to stderr. Capture both so this works across CLI versions.
OUTF=$(mktemp); ERRF=$(mktemp)
vercel sandbox create --runtime node24 --timeout "$TIMEOUT" -p "$PORT" \
  >"$OUTF" 2>"$ERRF" || { cat "$OUTF" "$ERRF" >&2; rm -f "$OUTF" "$ERRF"; exit 1; }
cat "$ERRF"
ID=$(head -1 "$OUTF" | tr -d '[:space:]')
[ -n "$ID" ] || ID=$(sed -n 's/.*Sandbox \([^ ]*\) created.*/\1/p' "$ERRF" | head -1)
URL=$(grep -hoE 'https://[a-z0-9-]+\.vercel\.run' "$OUTF" "$ERRF" | head -1)
rm -f "$OUTF" "$ERRF"
[ -n "$ID" ]  || { echo "error: could not determine sandbox id from create output"; exit 1; }
[ -n "$URL" ] || { echo "error: could not determine sandbox URL from create output"; exit 1; }
echo "Sandbox id: $ID"
echo "Public URL: $URL"

log "Uploading bundle and unpacking"
vercel sandbox cp "$BUNDLE" "$ID":/vercel/sandbox/bundle.tgz
vercel sandbox exec "$ID" bash -lc \
  'cd /vercel/sandbox && mkdir -p app && tar xzf bundle.tgz -C app && chmod +x app/rex-serve'

log "Starting rex-serve in the sandbox (kept alive as a background job)"
vercel sandbox exec "$ID" bash -lc \
  'cd /vercel/sandbox/app && exec ./rex-serve --dir . --port 3000' \
  >/tmp/rex-sandbox-server.log 2>&1 &
SERVER_JOB=$!

log "Waiting for the server via $URL/health"
ready=
for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL/health" || true)" = "200" ]; then
    ready=1; break
  fi
  sleep 2
done
[ -n "$ready" ] || { echo "error: server did not become ready (see /tmp/rex-sandbox-server.log)"; exit 1; }

log "HTTP checks"
printf '  /health        -> '; curl -s --max-time 10 "$URL/health"; echo
printf '  /              -> '; curl -s --max-time 10 "$URL/" | grep -oiE '<title>[^<]*</title>' | head -1 || true
printf '  /tour/cursors  -> '; curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 10 "$URL/tour/cursors"

log "WebSocket check — two clients on /__ws/cursors (through the *.vercel.run ingress)"
WS_URL="$URL" node <<'NODE'
const base = process.env.WS_URL.replace(/^http/, 'ws') + '/__ws/cursors';
const sub = new WebSocket(base);
let done = false;
const fin = (code, msg) => { if (done) return; done = true; console.log('  ' + msg); process.exit(code); };
sub.addEventListener('open', () => {
  const pub = new WebSocket(base);
  pub.addEventListener('open', () =>
    setTimeout(() => pub.send(JSON.stringify({ id: 'a', x: 0.2, y: 0.3, color: '#f00', name: 't' })), 200));
  pub.addEventListener('error', e => fin(1, 'publisher error: ' + (e.message || e)));
});
sub.addEventListener('message', ev => {
  const m = JSON.parse(ev.data.toString());
  fin(m.y === 0.7 && m.id === 'a' ? 0 : 1,
      m.y === 0.7
        ? 'PASS: static binary serves WebSockets in the sandbox (cursors transform y 0.3 -> 0.7)'
        : 'FAIL: unexpected payload ' + ev.data);
});
sub.addEventListener('error', e => fin(1, 'subscriber error: ' + (e.message || e)));
setTimeout(() => fin(1, 'TIMEOUT: no message (WS upgrade or broadcast failed)'), 10000);
NODE

log "All checks passed ✅"
