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

## Architecture

A single Vercel serverless function (`api/rex.rs`) handles all routes:

1. On cold start, `AppState::build()` loads the `.rexd` schema, type-checks all `.rex` files, and compiles them to bytecode
2. Each request is routed through the Rex middleware chain and matched handler
3. The Rex interpreter runs on `spawn_blocking` so the async event loop stays free
4. `http.fetch` uses async reqwest bridged via `Handle::block_on`

The Rex compiler and server library are pulled in via a git submodule pointing to the `rusty` branch of the [rex repo](https://github.com/creationix/rex).

## Project Structure

```
api/rex.rs          # Vercel function entry point
routes/             # Rex handler scripts (filesystem-routed)
  _middleware.rex   # Global middleware (security headers, view-source)
  _layouts/         # HTML templates
  index.rex         # Homepage
  health.rex        # JSON health check
  tour/             # Guided tour pages
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
