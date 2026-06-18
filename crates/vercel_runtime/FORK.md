# Forked `vercel_runtime`

This is a vendored fork of the official [`vercel_runtime`](https://crates.io/crates/vercel_runtime)
crate, added so the Vercel deployment of this demo can serve **WebSockets**.

- **Upstream:** https://github.com/vercel/vercel/tree/main/crates/vercel_runtime
- **Forked from:** `vercel_runtime` **2.2.0** (crates.io, published 2026-04-16)
- **License:** Apache-2.0 (see `LICENSE`)

## Why

The upstream runtime's connection loop serves connections **without** hyper's
`.with_upgrades()`, so HTTP/1.1 upgrade requests never complete — `hyper::upgrade::OnUpgrade`
is never injected into request extensions and the WebSocket handshake stalls. This is the same
gap the Python runtime closed in [vercel/vercel#15993](https://github.com/vercel/vercel/pull/15993)
("end the request at `websocket.accept` to match the Node.js detached-upgrade flow"); the Rust
runtime never got the equivalent.

Forking the crate (it is small and Apache-2.0) lets us ship WS on our own timeline without an
upstream PR + crates.io release on the critical path. The `@vercel/rust` **builder** is unchanged —
it compiles whatever runtime crate the binary links.

## Diff vs upstream 2.2.0

Only two edits, both marked with `// FORK:` comments:

1. **`src/lib.rs`** — the per-connection `http1::Builder::...serve_connection(...)` call gains
   `.with_upgrades()`. hyper then performs the upgrade and injects `OnUpgrade` into request
   extensions; axum's `WebSocketUpgrade` extractor picks it up. The per-request IPC `end` message
   is already sent immediately after the handler returns its response, so for a `101` it fires right
   at accept — matching the detached-upgrade contract.

2. **`src/axum/mod.rs`** — `StreamingUtils::process_response` short-circuits a
   `101 Switching Protocols` response, returning it with an empty body instead of running it through
   the streaming / `to_bytes` path. (Defensive: a 101 has no body anyway.)

No other files are modified. To re-sync with a newer upstream, re-vendor the source and re-apply the
two `// FORK:` hunks (or upstream them and drop this fork).
