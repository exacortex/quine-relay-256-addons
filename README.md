# `quine-relay-256-addons` — Verification & Container Add-On Kits

Ready-to-publish companion kits for [`exacortex/quine-relay-256`](https://github.com/exacortex/quine-relay-256):

1. **`tools/audit/`** — Drop-in reproducible verification kit for **Lap B** (in-image `QR.aj` regeneration + `"bad op " -> "Q'$@{( "` engine canary) and **Lap C** (full-build `strace` file + non-Unix socket audit).
2. **`polyglot-256/`** — Ready-to-publish GHCR kit turning the 256-language relay container into an interactive sandbox (`ghcr.io/exacortex/polyglot-256`) with `polyglot-info`, `CMD ["/bin/bash"]`, and a manual `workflow_dispatch` GitHub Actions workflow.

---

## 1. Dropping `tools/audit/` into `exacortex/quine-relay-256`

> **Important note on commit and repository hashes:** Committing `tools/audit/` to `exacortex/quine-relay-256`'s `main` branch changes the repository's Git tree hash, commit SHA, and Docker build context (`ADD . /usr/local/share/quine-relay` in `Dockerfile`), even though `src/`, `QR.aj`, `Makefile`, and `SHA256SUMS` remain untouched. If you want `main`'s published commit and file hashes frozen exactly as verified, either:
> - keep `tools/audit/` in a separate branch or companion directory, or
> - mount `tools/audit/` read-only at runtime via `-v` without committing it to `main`.

To integrate into a clone of `exacortex/quine-relay-256`:

```bash
mkdir -p /path/to/quine-relay-256/tools/audit
cp -a tools/audit/. /path/to/quine-relay-256/tools/audit/
cd /path/to/quine-relay-256

# Optional: commit on a dedicated branch instead of main
git checkout -b feat/audit-kit
git add tools/audit
git commit -m "tools/audit: add Lap B canary and Lap C strace audit kit"
```

From the `exacortex/quine-relay-256` repository root, see [tools/audit/README.md](tools/audit/README.md) for the exact Lap A, Lap B, and Lap C commands.

---

## 2. Publishing `polyglot-256` (`ghcr.io/exacortex/polyglot-256`)

### Option A: Local `docker build && docker push`

Build on top of a local `quine-relay-256` (or `qr256-v31-verify`) image, verify all 256 toolchains inside the built container, and push to GHCR:

```bash
cd polyglot-256
docker build --build-arg BASE_IMAGE=quine-relay-256 -f Dockerfile.polyglot -t ghcr.io/exacortex/polyglot-256:latest .
docker run --rm ghcr.io/exacortex/polyglot-256:latest polyglot-info --check
docker run --rm ghcr.io/exacortex/polyglot-256:latest polyglot-info --search Malbolge
docker push ghcr.io/exacortex/polyglot-256:latest
```

### Option B: GitHub Actions (`workflow_dispatch`)

Drop `polyglot-256/` and `polyglot-256/publish-ghcr.yml` into your repository's `.github/workflows/publish-ghcr.yml` (adjusting paths if placed at repo root) and trigger manually in GitHub Actions on a self-hosted Linux `x86_64` runner with `>= 45 GB` free disk:

```bash
mkdir -p /path/to/quine-relay-256/.github/workflows /path/to/quine-relay-256/polyglot-256
cp -a polyglot-256/. /path/to/quine-relay-256/polyglot-256/
mv /path/to/quine-relay-256/polyglot-256/publish-ghcr.yml /path/to/quine-relay-256/.github/workflows/publish-ghcr.yml
```

See [polyglot-256/README.md](polyglot-256/README.md) for interactive usage, LLM benchmark patterns, Rosetta Code examples, and `qr256-v31-verify` tagging one-liners.
