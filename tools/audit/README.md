# Audit Kit for `exacortex/quine-relay-256`

Self-contained scripts to reproduce **Lap B** (in-image seed regeneration + harsh engine-mutation canary) and **Lap C** (full-build `strace` file and non-Unix socket audit) cleanly against the `quine-relay-256` Docker image without touching the host repository.

## Files

- `trace-audit.py` — Parses a `strace -f` log (`.txt` or `.txt.gz`) and `Makefile`, attributing file opens/renames/links and non-Unix socket (`connect`/`sendto`/`sendmsg`) syscalls to each of the 256 relay steps. Exits `0` by default, `2` under `--strict-net` (any non-Unix socket) or `--strict` (any `READ-FOREIGN`, `WRITE-ODD`, or `NET` finding).
- `run-lap-b-canary.sh` — Rebuilds `QR.aj` from `src/` inside an ephemeral container to verify deterministic regeneration, then patches `"bad op "` -> `"Q'$@{( "` in `src/engine_body.java`, runs a full offline `make all`, and verifies `QR2.aj == QR.aj` with all 256 intermediate step hashes changed.
- `run-lap-c-trace.sh` — Runs `make all` under `strace -f`, verifies `QR.aj == QR2.aj` and `256/256` `SHA256SUMS`, archives intermediate artifacts, compresses `trace.txt.gz`, and runs `trace-audit.py --strict-net`.
- `Dockerfile.trace` — Layers `strace`, `run-lap-c-trace.sh`, and `trace-audit.py` onto `ARG BASE_IMAGE=quine-relay-256`.

## Usage (from `exacortex/quine-relay-256` repo root)

Assuming `tools/audit/` is dropped into `exacortex/quine-relay-256` and the base image is built as `quine-relay-256` (pass `--build-arg BASE_IMAGE=...` or change the image tag if yours differs):

### Lap A (Baseline offline `make check`)

```bash
docker run --rm --network=none quine-relay-256
```

### Lap B (In-image rebuild + `"Q'$@{( "` engine canary)

Runs strictly inside an ephemeral container (`--rm`) and writes results only to `./out/canary/`:

```bash
mkdir -p out
docker run --rm --network=none \
  -v "$(pwd)/out:/out" \
  -v "$(pwd)/tools/audit:/audit:ro" \
  --entrypoint bash \
  quine-relay-256 /audit/run-lap-b-canary.sh
```

Expected `out/canary/result.txt`:
- `REGEN_IDENTICAL=YES`
- `CANARY_IN_QR_AJ=1`, `CANARY_ROUNDTRIP=OK`, `CANARY_QR2_HAS_MARK=1`
- `STEP_HASH_CHANGED=256 UNCHANGED=0 MISSING=0`

### Lap C (Full `strace` syscall & socket audit)

Build the trace image (`~35 GB` base + `strace`) and run offline with `SYS_PTRACE`:

```bash
mkdir -p out
docker build -f tools/audit/Dockerfile.trace -t quine-relay-256-trace tools/audit
docker run --rm --network=none \
  --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
  -v "$(pwd)/out:/out" \
  quine-relay-256-trace
```

> **Note:** A full 256-step build peaks around `~21 GB` RSS during `Shakespeare` (`gcc -O0` on `QR.spl.c`); allocate **>= 24 GB RAM** to Docker before running Lap B or Lap C.

### Standalone `trace-audit.py`

Audit an existing trace log against `Makefile` locally:

```bash
python3 tools/audit/trace-audit.py out/trace/trace.txt.gz Makefile out/trace/audit.tsv
```

Add `--strict-net` to fail (exit `2`) on any non-Unix socket activity, or `--strict` to fail on any `READ-FOREIGN`, `WRITE-ODD`, or `NET` row.
