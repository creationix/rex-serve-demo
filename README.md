# rex-serve-demo

A demo deployment of [rex-serve](https://github.com/creationix/rex) on Vercel — Rex edge functions running as a serverless Rust function.

## What is this?

This is the knowledge-base example from the Rex project, deployed as a Vercel serverless function. It demonstrates:

- **Filesystem-routed Rex scripts** — `.rex` files as server-side handlers
- **Middleware chains** — `_middleware.rex` files that run before handlers
- **Tagged template literals** — the `html` tag auto-escapes interpolated values
- **JSON API with CRUD** — backed by Upstash Redis on Vercel and SQLite locally
- **External API proxying** — `http.fetch` calls the Deseret Alphabet translator API
- **Unicode support** — Deseret script characters (U+10400–U+1044F, 4-byte UTF-8)
- **Type checking** — all routes are type-checked at build time via `.rexd` domain schema
- **WebSockets** — `/__ws/{channel}` pub/sub with optional `_ws/{channel}.rex` transforms (the live cursors demo at `/tour/cursors`)

## Architecture

A single Vercel serverless function (`api/rex.rs`) handles all routes:

1. On cold start, `AppState::build()` loads the `.rexd` schema, type-checks all `.rex` files, and compiles them to bytecode
2. Each request is routed through the Rex middleware chain and matched handler
3. The Rex interpreter runs on `spawn_blocking` so the async event loop stays free
4. `http.fetch` uses async reqwest bridged via `Handle::block_on`
5. `db.*` uses Upstash's REST API when its Vercel environment variables are present, otherwise SQLite

The Rex compiler and server library are pulled in via a git submodule pointing to the `rusty` branch of the [rex repo](https://github.com/creationix/rex).

### WebSockets on Vercel

The `/__ws/{channel}` endpoint upgrades to a WebSocket and joins an in-process pub/sub channel;
inbound messages optionally run through a compiled `_ws/{channel}.rex` transform before being
published to every subscriber (the `/tour/cursors` demo mirrors cursor positions this way).

Vercel's WebSocket support uses a **detached-upgrade** model: the function writes the `101`, then the
platform tunnels the socket. WebSocket upgrades are supported by `vercel_runtime` 2.3 and later via
[vercel/vercel#16708](https://github.com/vercel/vercel/pull/16708).

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

# Add the API secret (use the same value in the Authorization header)
vercel env add REX_SECRET_API_KEY

# Deploy
vercel deploy
```

### Configure durable storage

Install the [Upstash Redis integration](https://vercel.com/marketplace/upstash) on the Vercel
project and select its Free plan. The integration injects `KV_REST_API_URL` and
`KV_REST_API_TOKEN` (rex-serve also accepts the Upstash-native `UPSTASH_REDIS_REST_URL` /
`UPSTASH_REDIS_REST_TOKEN`); it detects them automatically because this project's
`db.backend` is `"auto"`. Redeploy after connecting the database.

Without those variables, `db.*` falls back to the local SQLite file configured in
`rex-serve.toml`. A partial Upstash configuration fails startup instead of silently using
ephemeral storage.

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
REX_SECRET_API_KEY=demo cargo run -p rex-serve -- --dir ../. --port 4000
```

Then visit http://localhost:4000.

## Run as a container (Docker)

The [`Dockerfile`](Dockerfile) is a multi-stage **Alpine/musl** build: a `rust:alpine` stage compiles
a fully static `rex-serve` binary, and a minimal `alpine` runtime stage runs it. Because the server
uses native `axum::serve`, WebSockets work in the container — so this image runs the Rex app (HTTP
**and** the `/__ws/{channel}` pub/sub demo) on any container host (Cloud Run, Fly, Kubernetes, a
Vercel Sandbox, …); no `vercel_runtime` involved.

```sh
git submodule update --init --recursive   # the build copies the rex submodule
docker build -t rex-serve .
docker run --rm -p 3000:3000 -e REX_SECRET_API_KEY=demo rex-serve
```

Then visit http://localhost:3000 (and `ws://localhost:3000/__ws/cursors`). The image is ~20 MB (a
static musl binary on Alpine); `data.db` is created inside the container at runtime — mount a volume
at `/app/data.db` to persist it.

## Testing in a Vercel Sandbox

The standalone server can also run in a [Vercel Sandbox](https://vercel.com/docs/vercel-sandbox) — a
real Linux microVM — and WebSockets work through its `*.vercel.run` ingress.

```sh
scripts/sandbox-run.sh
```

The script builds the static `x86_64` musl binary on the host with Docker (via the
[`Dockerfile`](Dockerfile) above), uploads just that ~10 MB binary plus the project files to a fresh
sandbox, runs it, and verifies HTTP **and** a two-client WebSocket round-trip through the public URL
— then removes the sandbox. Because the binary is static, the sandbox needs no Rust toolchain,
compiler, or Docker, so it's serving in seconds. Env overrides: `TIMEOUT`, `KEEP=1` (leave it running
to poke at).

Prerequisites: Docker, a Vercel CLI with `vercel sandbox` (logged in, project linked), and Node 21+.
