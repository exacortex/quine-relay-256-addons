#!/usr/bin/env bash
# Reproduce Lap C inside a trace-enabled container:
#   Run full `make all` under `strace -f`, verify QR.aj == QR2.aj and 256/256
#   SHA256SUMS, archive step outputs, compress the trace, and run trace-audit.py
#   (checking files and non-Unix sockets).

set -uo pipefail

OUT_DIR="${OUT_DIR:-/out/trace}"
RELAY_DIR="${RELAY_DIR:-/usr/local/share/quine-relay}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f /usr/local/bin/trace-audit.py ]; then
  AUDIT_SCRIPT="${AUDIT_SCRIPT:-/usr/local/bin/trace-audit.py}"
else
  AUDIT_SCRIPT="${AUDIT_SCRIPT:-$SCRIPT_DIR/trace-audit.py}"
fi

usage() {
  cat <<'EOF'
Usage: run-lap-c-trace.sh [--out-dir DIR] [--relay-dir DIR] [--audit-script PATH]

Runs Lap C (full 256-step `make all` under `strace -f`, SHA-256 check, and
trace-audit.py file + non-Unix socket audit).

Options:
  --out-dir DIR       Output directory (default: /out/trace)
  --relay-dir DIR     Relay directory inside container (default: /usr/local/share/quine-relay)
  --audit-script PATH Path to trace-audit.py (default: /usr/local/bin/trace-audit.py)
  -h, --help          Show this help message
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
    --audit-script)
      AUDIT_SCRIPT="$2"
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

command -v strace >/dev/null 2>&1 || { echo "strace not found in container" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found in container" >&2; exit 1; }
[ -f "$AUDIT_SCRIPT" ] || { echo "Audit script not found: $AUDIT_SCRIPT" >&2; exit 1; }

cd "$RELAY_DIR" || exit 1
mkdir -p "$OUT_DIR"
: > "$OUT_DIR/result.txt"

SECONDS=0
strace -f -qq -s 300 -e signal=none -o "$OUT_DIR/trace.txt" \
  -e trace=execve,execveat,open,openat,openat2,creat,rename,renameat,renameat2,link,linkat,symlink,symlinkat,clone,clone3,fork,vfork,chdir,connect \
  make all < /dev/null > "$OUT_DIR/make.log" 2>&1
make_rc=$?
echo "MAKE_RC=$make_rc SECS=$SECONDS" >> "$OUT_DIR/result.txt"

if [ -f QR2.aj ] && cmp -s QR.aj QR2.aj; then
  roundtrip="OK"
else
  roundtrip="FAIL"
fi
echo "ROUNDTRIP=$roundtrip" >> "$OUT_DIR/result.txt"

sha256sum -c SHA256SUMS > "$OUT_DIR/sums.txt" 2>&1 || true
sums_ok=$(grep -c ': OK$' "$OUT_DIR/sums.txt" || true)
sums_failed=$(grep -c ': FAILED' "$OUT_DIR/sums.txt" || true)
echo "SUMS_OK=$sums_ok FAILED=$sums_failed" >> "$OUT_DIR/result.txt"

tar cf "$OUT_DIR/qr-files.tar" QR* qr* qr_cs/QR.cs qr_vb/QR.vb qrgleam/src/qr.gleam qrpony/main.pony 2>/dev/null || true
gzip -f "$OUT_DIR/trace.txt"

python3 "$AUDIT_SCRIPT" --root "$RELAY_DIR" --strict-net "$OUT_DIR/trace.txt.gz" Makefile "$OUT_DIR/audit.tsv" > "$OUT_DIR/audit.log" 2>&1
audit_rc=$?
net_count=$(awk -F'\t' 'NR>1 && $2=="NET" {c++} END {print c+0}' "$OUT_DIR/audit.tsv")
echo "AUDIT_RC=$audit_rc NET_FINDINGS=$net_count" >> "$OUT_DIR/result.txt"

cat "$OUT_DIR/result.txt"

if [ "$make_rc" -ne 0 ] || [ "$roundtrip" != "OK" ] || [ "$sums_failed" -ne 0 ] || [ "$audit_rc" -ne 0 ]; then
  exit 1
fi
