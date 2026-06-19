# syntax=docker/dockerfile:1
#
# Multi-stage build for the standalone rex-serve dev server.
#
# Produces a tiny Alpine/musl-based image that runs `rex-serve` over native
# `axum::serve` — WebSocket upgrades work out of the box, so this image runs the
# Rex app (HTTP + the /__ws/{channel} pub/sub demo) on any container host
# (Cloud Run, Fly, Kubernetes, a Vercel Sandbox, …). No `vercel_runtime` needed;
# that's only for the serverless function entry point (api/rex.rs).
#
# Because the build produces a fully static musl binary, the same Dockerfile
# also serves `scripts/sandbox-run.sh`, which extracts the binary and uploads it
# to a Vercel Sandbox (no toolchain or Docker needed in the sandbox).
#
# Build (from the repo root, with submodules checked out):
#   git submodule update --init --recursive
#   docker build -t rex-serve .
# Run:
#   docker run --rm -p 3000:3000 rex-serve
#   # then: http://localhost:3000  and  ws://localhost:3000/__ws/cursors

# ---- build stage --------------------------------------------------------------
# rust:alpine targets musl natively, so `cargo build` yields a statically
# linked musl binary. The toolchain it ships is minimal, so add what the C/asm
# deps need: musl-dev + gcc for rusqlite's bundled SQLite, and make + perl for
# ring's (rustls) build scripts. TLS is rustls/ring — no OpenSSL, no cmake.
FROM rust:alpine AS build
WORKDIR /src
RUN apk add --no-cache build-base perl

# Build the standalone server from the rex submodule workspace. Building
# `-p rex-serve` against rex/Cargo.toml avoids the demo crate, which has a git
# dependency on the vercel monorepo (not needed for the standalone server).
COPY rex/ rex/
RUN cargo build --release -p rex-serve --manifest-path rex/Cargo.toml \
 && strip rex/target/release/rex-serve

# ---- runtime stage ------------------------------------------------------------
FROM alpine:3.20 AS runtime
# ca-certificates lets http.fetch reach external HTTPS APIs (e.g. the Deseret demo).
RUN apk add --no-cache ca-certificates
WORKDIR /app

# Project files rex-serve reads at runtime: routes, server config, domain schema.
COPY routes/ routes/
COPY rex-serve.toml rex-serve.rexd ./
COPY --from=build /src/rex/target/release/rex-serve /usr/local/bin/rex-serve

# rex-serve.toml binds host 0.0.0.0; --dir points at the project root above.
EXPOSE 3000
CMD ["rex-serve", "--dir", "/app", "--port", "3000"]
