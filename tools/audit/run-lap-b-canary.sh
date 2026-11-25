#!/usr/bin/env bash
# Reproduce Lap B inside an ephemeral container:
#   1. Rebuild QR.aj from src/ and verify byte-exact identity with the committed seed.
#   2. Apply the harsh engine canary ("bad op " -> "Q'$@{( " in src/engine_body.java),
#      run a full offline 256-step `make all` lap, and verify QR2.aj == QR.aj and
#      256/256 intermediate step SHA-256 hashes changed.
#
# Intended to run inside `docker run --rm --network=none ...` so the host repo
# is never modified; only OUT_DIR receives logs and summary files.

set -uo pipefail

OUT_DIR="${OUT_DIR:-/out/canary}"
RELAY_DIR="${RELAY_DIR:-/usr/local/share/quine-relay}"

usage() {
  cat <<'EOF'
Usage: run-lap-b-canary.sh [--out-dir DIR] [--relay-dir DIR]

Runs Lap B (in-image QR.aj regeneration + "bad op " -> "Q'$@{( " engine canary)
inside the container without modifying any host repository files.

Options:
  --out-dir DIR    Directory for canary logs and result.txt (default: /out/canary)
  --relay-dir DIR  Relay directory inside container (default: /usr/local/share/quine-relay)
  -h, --help       Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --relay-dir)
      RELAY_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -d "$RELAY_DIR/.git" ] && [ "${ALLOW_GIT_DIR:-0}" != "1" ]; then
  echo "Refusing to mutate a git checkout at $RELAY_DIR (run inside Docker or set ALLOW_GIT_DIR=1)." >&2
  exit 1
fi

cd "$RELAY_DIR" || exit 1
mkdir -p "$OUT_DIR"
: > "$OUT_DIR/result.txt"

sha256sum QR.aj > "$OUT_DIR/pushed.sha"
(cd src && rake lazyk-boot.dat blc-boot.dat grass-boot.dat && ruby gen-aj.rb) > "$OUT_DIR/regen.log" 2>&1
regen_rc=$?
if [ "$regen_rc" -ne 0 ]; then
  echo "REGEN_RC=$regen_rc" >> "$OUT_DIR/result.txt"
  cat "$OUT_DIR/regen.log" >&2
  exit "$regen_rc"
fi

sha256sum QR.aj > "$OUT_DIR/regen.sha"
if diff -q <(cut -c1-64 "$OUT_DIR/pushed.sha") <(cut -c1-64 "$OUT_DIR/regen.sha") > /dev/null; then
  echo "REGEN_IDENTICAL=YES" >> "$OUT_DIR/result.txt"
else
  echo "REGEN_IDENTICAL=NO" >> "$OUT_DIR/result.txt"
fi

if ! grep -qF '"bad op "' src/engine_body.java; then
  echo 'Expected literal "bad op " not found in src/engine_body.java' >&2
  exit 1
fi

sed -i "s/\"bad op \"/\"Q'\$@{( \"/" src/engine_body.java
(cd src && ruby gen-aj.rb) >> "$OUT_DIR/regen.log" 2>&1
canary_gen_rc=$?
if [ "$canary_gen_rc" -ne 0 ]; then
  echo "CANARY_GEN_RC=$canary_gen_rc" >> "$OUT_DIR/result.txt"
  cat "$OUT_DIR/regen.log" >&2
  exit "$canary_gen_rc"
fi

canary_in_aj=$(grep -cF "Q'\$@{(" QR.aj || true)
echo "CANARY_IN_QR_AJ=$canary_in_aj" >> "$OUT_DIR/result.txt"
echo "CANARY_QR_AJ_BYTES=$(wc -c < QR.aj)" >> "$OUT_DIR/result.txt"
echo "CANARY_QR_AJ_SHA256=$(sha256sum QR.aj | awk '{print $1}')" >> "$OUT_DIR/result.txt"
cp QR.aj "$OUT_DIR/QR.aj.canary"

SECONDS=0
make all < /dev/null > "$OUT_DIR/make.log" 2>&1
make_rc=$?
echo "MAKE_RC=$make_rc SECS=$SECONDS" >> "$OUT_DIR/result.txt"

if [ -f QR2.aj ] && cmp -s QR.aj QR2.aj; then
  roundtrip="OK"
else
  roundtrip="FAIL"
fi
echo "CANARY_ROUNDTRIP=$roundtrip" >> "$OUT_DIR/result.txt"

canary_in_qr2=0
if [ -f QR2.aj ]; then
  canary_in_qr2=$(grep -cF "Q'\$@{(" QR2.aj || true)
fi
echo "CANARY_QR2_HAS_MARK=$canary_in_qr2" >> "$OUT_DIR/result.txt"

sha256sum -c SHA256SUMS > "$OUT_DIR/sums.txt" 2>&1 || true
changed=$(grep -c ': FAILED' "$OUT_DIR/sums.txt" || true)
unchanged=$(grep -c ': OK$' "$OUT_DIR/sums.txt" || true)
missing=$(grep -c 'No such file' "$OUT_DIR/sums.txt" || true)
echo "STEP_HASH_CHANGED=$changed UNCHANGED=$unchanged MISSING=$missing" >> "$OUT_DIR/result.txt"

cat "$OUT_DIR/result.txt"

if [ "$make_rc" -ne 0 ] || [ "$roundtrip" != "OK" ] || [ "$canary_in_qr2" -eq 0 ] || [ "$unchanged" -ne 0 ] || [ "$missing" -ne 0 ]; then
  exit 1
fi
