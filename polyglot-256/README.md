# `polyglot-256` — 256-Language Polyglot Container Kit (`ghcr.io/exacortex/polyglot-256`)

Turns the `exacortex/quine-relay-256` Ubuntu 26.04 container (`~32.5 GB`, 256 compilers and interpreters from AspectJ and Zig to Malbolge Unshackled, Idris 2, Lean 4, Gleam, 6502 asm, and Uxntal) into a general-purpose interactive polyglot sandbox.

## What `Dockerfile.polyglot` Changes

- Layers directly on `ARG BASE_IMAGE=quine-relay-256` (`FROM ${BASE_IMAGE}`).
- Clears any `ENTRYPOINT` and sets `CMD ["/bin/bash"]` so containers drop into an interactive shell (or accept arbitrary commands) instead of running a 38-minute `make check`.
- Adds `/usr/local/share/quine-relay/vendor/local/bin` and `/usr/games` to `PATH` and sets `QUINE_RELAY_DIR=/usr/local/share/quine-relay`.
- Installs `polyglot-info` into `/usr/local/bin/polyglot-info` and verifies all 256 toolchains during build (`polyglot-info --check`).
- Sets standard `org.opencontainers.image.*` OCI metadata labels.

## Files

- `Dockerfile.polyglot` — Thin layer converting `quine-relay-256` into `polyglot-256`.
- `polyglot-info` — Pure Python 3 stdlib CLI listing all 256 languages, file extensions, and exact Makefile compiler/interpreter invocations (`--list`, `--json`, `--search <query>`, `--check`).
- `publish-ghcr.yml` — Manual GitHub Actions `workflow_dispatch` workflow for a self-hosted Linux `x86_64` runner to build, verify (`polyglot-info --check`), and push `ghcr.io/exacortex/polyglot-256`.
- `squash-installs.rb` — Cleaned standalone helper with usage docs for squashing consecutive `RUN` instructions from modular install files into overlay2-friendly Docker layers.

## Quick Start

### 1. Build Locally from `quine-relay-256` (or `qr256-v31-verify`)

```bash
# From a built quine-relay-256 base image:
docker build -f Dockerfile.polyglot -t ghcr.io/exacortex/polyglot-256:latest .

# Or directly from an existing local qr256-v31-verify image:
docker build --build-arg BASE_IMAGE=qr256-v31-verify -f Dockerfile.polyglot -t ghcr.io/exacortex/polyglot-256:latest .
```

### 2. Tag & Push One-Liners (from existing local `qr256-v31-verify`)

Recommended (layers `polyglot-info`, `CMD ["/bin/bash"]`, `PATH`, and OCI labels cleanly on top of `qr256-v31-verify`):

```bash
docker build --build-arg BASE_IMAGE=qr256-v31-verify -f Dockerfile.polyglot -t ghcr.io/exacortex/polyglot-256:latest . && docker push ghcr.io/exacortex/polyglot-256:latest
```

Direct tag-and-push of the raw base image without adding `polyglot-info` / bash default `CMD`:

```bash
docker tag qr256-v31-verify ghcr.io/exacortex/polyglot-256:v3.1-raw && docker push ghcr.io/exacortex/polyglot-256:v3.1-raw
```

## Using `polyglot-256`

### Interactive Shell & Toolchain Discovery (`polyglot-info`)

```bash
# Drop into bash with all 256 languages on PATH
docker run --rm -it ghcr.io/exacortex/polyglot-256:latest

# Inspect toolchains without starting an interactive shell
docker run --rm ghcr.io/exacortex/polyglot-256:latest polyglot-info --list
docker run --rm ghcr.io/exacortex/polyglot-256:latest polyglot-info --search Malbolge
docker run --rm ghcr.io/exacortex/polyglot-256:latest polyglot-info --json > languages-256.json
docker run --rm ghcr.io/exacortex/polyglot-256:latest polyglot-info --check
```

### LLM Polyglot Benchmarks & Evals

Run untrusted or model-generated solutions across 256 languages offline inside `--network=none` with bounded memory and CPU:

```bash
docker run --rm --network=none --cpus=4 --memory=8g \
  -v "$(pwd)/solutions:/work:ro" -w /work \
  ghcr.io/exacortex/polyglot-256:latest \
  bash -lc '
    cp hello.zig /tmp/hello.zig && zig run /tmp/hello.zig
    cp hello.gleam /tmp/ && gleam --version
    unshackled /work/hello.mb < /dev/null
  '
```

Use `polyglot-info --json` to dynamically map each benchmark language name or extension (`.aj`, `.fish.fish`, `.k.k`, `.mb`, `.wl`, `.tal`, `.s65`, etc.) to its verified compiler/interpreter command inside the container.

### Rosetta Code & Multi-Language Experiments

Mount a local directory of Rosetta Code snippets and compile/run them in one container:

```bash
docker run --rm -v "$(pwd):/work" -w /work ghcr.io/exacortex/polyglot-256:latest \
  bash -lc '
    rustc sieve.rs -o /tmp/sieve && /tmp/sieve
    uiua run --no-format sieve.ua
    koka -v0 -o /tmp/sieve_kk sieve.kk && /tmp/sieve_kk
  '
```

> **Permissions note:** The container defaults to non-root `USER qr` (`uid=1001`, `HOME=/home/qr`) so pre-warmed `.NET`, `NuGet`, `Ballerina`, `Cargo`, and `Go` caches resolve offline. If mounting a host directory owned by another UID for writing, either write outputs to `/tmp` or pass `--user root` (keeping `HOME=/home/qr` if offline caches are needed).
