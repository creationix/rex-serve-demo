# syntax=docker/dockerfile:1
#
# Multi-stage build for the standalone rex-serve dev server.
#
# Produces a small Debian-based image that runs `rex-serve` over native
# `axum::serve` — WebSocket upgrades work out of the box, so this image runs the
# Rex app (HTTP + the /__ws/{channel} pub/sub demo) on any container host
# (Cloud Run, Fly, Kubernetes, a Vercel Sandbox, …). No `vercel_runtime` needed;
# that's only for the serverless function entry point (api/rex.rs).
#
# Build (from the repo root, with submodules checked out):
#   git submodule update --init --recursive
#   docker build -t rex-serve .
# Run:
#   docker run --rm -p 3000:3000 rex-serve
#   # then: http://localhost:3000  and  ws://localhost:3000/__ws/cursors

# ---- build stage --------------------------------------------------------------
# rust:1-bookworm is based on buildpack-deps, so gcc/perl/make are already present
# (enough for rusqlite's bundled SQLite and reqwest's ring-backed rustls).
FROM rust:1-bookworm AS build
WORKDIR /src

# Build the standalone server from the rex submodule workspace. Building
# `-p rex-serve` against rex/Cargo.toml avoids the demo crate, which has a git
# dependency on the vercel monorepo (not needed for the standalone server).
COPY rex/ rex/
RUN cargo build --release -p rex-serve --manifest-path rex/Cargo.toml \
 && strip rex/target/release/rex-serve

# ---- runtime stage ------------------------------------------------------------
FROM debian:bookworm-slim AS runtime
# ca-certificates lets http.fetch reach external HTTPS APIs (e.g. the Deseret demo).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Project files rex-serve reads at runtime: routes, server config, domain schema.
COPY routes/ routes/
COPY rex-serve.toml rex-serve.rexd ./
COPY --from=build /src/rex/target/release/rex-serve /usr/local/bin/rex-serve

# rex-serve.toml binds host 0.0.0.0; --dir points at the project root above.
EXPOSE 3000
CMD ["rex-serve", "--dir", "/app", "--port", "3000"]
