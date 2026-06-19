#!/usr/bin/env bash
#
# sandbox-test.sh — run the standalone rex-serve dev server in a Vercel Sandbox
# and verify HTTP + WebSockets work through the public *.vercel.run ingress.
#
# This exercises a different compute model from the serverless function
# (api/rex.rs): a Sandbox is a real Linux VM, so rex-serve runs unmodified —
# native `axum::serve` handles WebSocket upgrades, no `vercel_runtime` needed.
#
# Prerequisites:
#   - Vercel CLI with `vercel sandbox` (>= 54.9), logged in (`vercel login`)
#   - A linked project (`vercel link`), or pass --project/--scope via VERCEL_* env
#   - Node 21+ locally (provides a global WebSocket for the test client)
#
# Usage:
#   scripts/sandbox-test.sh
#
# Env overrides:
#   REPO_URL=<git url>   repo to clone in the sandbox (default: this repo on GitHub)
#   REF=<branch|tag>     ref to test (default: main)
#   VCPUS=<n>            vCPUs for a faster build (default: 4)
#   TIMEOUT=<dur>        sandbox lifetime (default: 30m)
#   KEEP=1               leave the sandbox running on exit (for debugging)
#
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/creationix/rex-serve-demo.git}"
REF="${REF:-main}"
PORT=3000
TIMEOUT="${TIMEOUT:-30m}"
VCPUS="${VCPUS:-4}"
KEEP="${KEEP:-}"
ID=""
SERVER_JOB=""

command -v vercel >/dev/null || { echo "error: Vercel CLI not found (need 'vercel sandbox')"; exit 1; }
command -v node   >/dev/null || { echo "error: node not found (need Node 21+ for the WS test)"; exit 1; }

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

log "Creating sandbox (port $PORT, ${VCPUS} vCPUs, timeout $TIMEOUT)"
# The CLI emits the machine identifier exec/rm expect (a name, or an sbx_… id,
# depending on version) on stdout; the decorative box and the *.vercel.run URL
# go to stderr. Capture both streams separately so this works across versions.
OUTF=$(mktemp); ERRF=$(mktemp)
vercel sandbox create --runtime node24 --timeout "$TIMEOUT" --vcpus "$VCPUS" -p "$PORT" \
  >"$OUTF" 2>"$ERRF" || { cat "$OUTF" "$ERRF" >&2; rm -f "$OUTF" "$ERRF"; exit 1; }
cat "$ERRF"
ID=$(head -1 "$OUTF" | tr -d '[:space:]')
# Fallback for versions that print "✅ Sandbox <id> created" instead of a bare id.
[ -n "$ID" ] || ID=$(sed -n 's/.*Sandbox \([^ ]*\) created.*/\1/p' "$ERRF" | head -1)
URL=$(grep -hoE 'https://[a-z0-9-]+\.vercel\.run' "$OUTF" "$ERRF" | head -1)
rm -f "$OUTF" "$ERRF"
[ -n "$ID" ]  || { echo "error: could not determine sandbox id from create output"; exit 1; }
[ -n "$URL" ] || { echo "error: could not determine sandbox URL from create output"; exit 1; }
echo "Sandbox id: $ID"
echo "Public URL: $URL"

log "Installing build toolchain (gcc, make, cmake) — base image is Amazon Linux 2023"
vercel sandbox exec "$ID" --sudo bash -lc 'dnf install -y gcc gcc-c++ make cmake perl'

log "Installing Rust, cloning '$REF', building rex-serve (a few minutes)"
vercel sandbox exec "$ID" --timeout 20m bash -lc '
  set -euo pipefail
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  . "$HOME/.cargo/env"
  # .gitmodules points at an SSH URL; rewrite SSH->HTTPS so the rex submodule
  # clones in this keyless environment.
  git config --global url."https://github.com/".insteadOf "git@github.com:"
  git clone --branch '"$REF"' --recurse-submodules '"$REPO_URL"' app
  # Build the standalone server from the rex submodule workspace (avoids the
  # demo crate, which has a git dependency on the vercel monorepo).
  cd app/rex
  cargo build -p rex-serve
  test -x target/debug/rex-serve
  echo "build ok"
'

log "Starting rex-serve in the sandbox (kept alive as a background job)"
vercel sandbox exec "$ID" bash -lc \
  'cd /vercel/sandbox/app && exec rex/target/debug/rex-serve --dir . --port 3000' \
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
        ? 'PASS: WebSockets work in the sandbox (cursors transform mirrored y 0.3 -> 0.7)'
        : 'FAIL: unexpected payload ' + ev.data);
});
sub.addEventListener('error', e => fin(1, 'subscriber error: ' + (e.message || e)));
setTimeout(() => fin(1, 'TIMEOUT: no message (WS upgrade or broadcast failed)'), 10000);
NODE

log "All checks passed ✅"
