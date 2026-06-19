# rex-serve-demo

A demo deployment of [rex-serve](https://github.com/creationix/rex) on Vercel — Rex edge functions running as a serverless Rust function.

## What is this?

This is the knowledge-base example from the Rex project, deployed as a Vercel serverless function. It demonstrates:

- **Filesystem-routed Rex scripts** — `.rex` files as server-side handlers
- **Middleware chains** — `_middleware.rex` files that run before handlers
- **Tagged template literals** — the `html` tag auto-escapes interpolated values
- **JSON API with CRUD** — backed by SQLite KV store
- **External API proxying** — `http.fetch` calls the Deseret Alphabet translator API
- **Unicode support** — Deseret script characters (U+10400–U+1044F, 4-byte UTF-8)
- **Type checking** — all routes are type-checked at build time via `.rexd` domain schema
- **WebSockets** — `/__ws/{channel}` pub/sub with optional `_ws/{channel}.rex` transforms (the live cursors demo at `/tour/cursors`), working on Vercel via a patched runtime crate — see below

## Architecture

A single Vercel serverless function (`api/rex.rs`) handles all routes:

1. On cold start, `AppState::build()` loads the `.rexd` schema, type-checks all `.rex` files, and compiles them to bytecode
2. Each request is routed through the Rex middleware chain and matched handler
3. The Rex interpreter runs on `spawn_blocking` so the async event loop stays free
4. `http.fetch` uses async reqwest bridged via `Handle::block_on`

The Rex compiler and server library are pulled in via a git submodule pointing to the `rusty` branch of the [rex repo](https://github.com/creationix/rex).

### WebSockets on Vercel

The `/__ws/{channel}` endpoint upgrades to a WebSocket and joins an in-process pub/sub channel;
inbound messages optionally run through a compiled `_ws/{channel}.rex` transform before being
published to every subscriber (the `/tour/cursors` demo mirrors cursor positions this way).

Vercel's WebSocket support uses a **detached-upgrade** model (the function writes the `101`, the
platform then tunnels the socket), but stock `vercel_runtime` serves connections *without* hyper's
`.with_upgrades()`, so the handshake can never complete. The fix is two edits — `.with_upgrades()`
plus a `101` passthrough — submitted upstream as
[vercel/vercel#16708](https://github.com/vercel/vercel/pull/16708). Until that lands on crates.io,
`Cargo.toml` depends on the PR branch directly:

```toml
vercel_runtime = { git = "https://github.com/vercel/vercel", branch = "rust-websocket-upgrades", features = ["axum"] }
```

Once `vercel_runtime` 2.3.0 is published, switch back to `version = "2.3"`. The `@vercel/rust` builder
is unchanged; it compiles whatever runtime crate the binary links.

> **Caveat — single instance.** The pub/sub broadcast is in-process, so only clients sharing one
> running instance see each other's messages. On Vercel Fluid that's typically one warm instance, but
> under scale-out, clients on different instances won't be connected. Cross-instance fan-out would need
> an external pub/sub (e.g. Redis/Upstash or Vercel KV) — future work.

## Project Structure

```
api/rex.rs          # Vercel function entry point
routes/             # Rex handler scripts (filesystem-routed)
  _middleware.rex   # Global middleware (security headers, view-source)
  _layouts/         # HTML templates
  _ws/              # WebSocket channel transforms (e.g. cursors.rex)
  index.rex         # Homepage
  health.rex        # JSON health check
  tour/             # Guided tour pages (includes the cursors WS demo)
  api/              # JSON API endpoints
rex-serve.rexd      # Domain type interface (opcodes, types, externs)
rex-serve.toml      # Server configuration
rex/                # Git submodule → github.com/creationix/rex (rusty branch)
vercel.json         # Vercel routing and function config
```

## Deployment

### Prerequisites

- [Vercel CLI](https://vercel.com/docs/cli) installed
- A Vercel account

### Deploy

```sh
# Clone with submodules
git clone --recurse-submodules https://github.com/creationix/rex-serve-demo.git
cd rex-serve-demo

# Link to your Vercel project
vercel link

# Deploy
vercel deploy
```

### Updating the Rex submodule

```sh
cd rex
git pull origin rusty
cd ..
git add rex
git commit -m "Update rex submodule"
git push
```

## Local Development

Run the standalone rex-serve binary (no Vercel required):

```sh
cd rex
cargo run -p rex-serve -- --dir ../. --port 4000
```

Then visit http://localhost:4000.

## Testing in a Vercel Sandbox

As an alternative to the serverless function, the standalone `rex-serve` dev server can run
in a [Vercel Sandbox](https://vercel.com/docs/vercel-sandbox) — a real Linux microVM. Because
it serves via native `axum::serve` (which handles WebSocket upgrades itself), it runs there
unmodified: **no `vercel_runtime` needed**, and WebSockets work through the Sandbox's
`*.vercel.run` ingress.

```sh
scripts/sandbox-test.sh
```

The script creates a sandbox, installs Rust + a C toolchain, clones this repo, builds
`rex-serve`, runs it, and verifies HTTP **and** a two-client WebSocket round-trip through the
public URL — then removes the sandbox. Overrides via env: `REF` (branch/tag), `VCPUS`,
`TIMEOUT`, `KEEP=1` (leave it running to poke at).

Prerequisites: a recent Vercel CLI with `vercel sandbox` (logged in, project linked) and Node 21+
locally. Notes baked into the script: the Sandbox base image is **Amazon Linux 2023** (no compiler
or Rust by default), and `.gitmodules` uses an SSH URL, so it rewrites SSH→HTTPS
(`git config url."https://github.com/".insteadOf "git@github.com:"`) before fetching the `rex`
submodule.

## Run as a container (Docker)

The [`Dockerfile`](Dockerfile) is a multi-stage build of the standalone `rex-serve` server: a Rust
build stage compiles the binary, and a slim Debian runtime stage runs it. Because the server uses
native `axum::serve`, WebSockets work in the container — so this image runs the Rex app (HTTP **and**
the `/__ws/{channel}` pub/sub demo) on any container host (Cloud Run, Fly, Kubernetes, a Vercel
Sandbox, …); no `vercel_runtime` involved.

```sh
git submodule update --init --recursive   # the build copies the rex submodule
docker build -t rex-serve .
docker run --rm -p 3000:3000 rex-serve
```

Then visit http://localhost:3000 (and `ws://localhost:3000/__ws/cursors`). The resulting image is
~115 MB; `data.db` is created inside the container at runtime — mount a volume at `/app/data.db` to
persist it.
