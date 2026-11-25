#!/usr/bin/env python3
"""Audit strace logs of Quine Relay 256 `make all` runs for file and socket purity.

Attributes every file and socket syscall of a `strace -f` log to its relay step
(via the `##  N: A -> B  ##` banner emitted before each Makefile step) and flags:
  - READ-FOREIGN: reads of relay-dir files other than the step's own input,
    files written earlier in the same step, or files under vendor/
  - WRITE-ODD: writes inside the relay dir outside standard output prefixes
  - RENAME: renames/links touching tracked paths
  - NET: non-Unix socket activity (connect/sendto/sendmsg with sa_family != AF_UNIX)

By default exits 0 after writing the TSV report. Pass --strict to exit 2 on any
READ-FOREIGN, WRITE-ODD, or NET finding, or --strict-net to exit 2 on NET only.
"""

from __future__ import annotations

import argparse
import collections
import gzip
import os
import re
import sys

DEFAULT_ROOT = "/usr/local/share/quine-relay"

RULE_RE = re.compile(r"^((?:QR|qr)[^:\s]*|QR2\.aj):\s*(\S+)\s*$")
LINE_RE = re.compile(r"^(?:\[pid\s+(\d+)\]|(\d+))\s+(.*)$")
CALL_RE = re.compile(r"^(\w+)\((.*)\)\s+=\s+(-?\d+|\?)(.*)$")
RESUMED_RE = re.compile(r"^<\.\.\. (\w+) resumed>(.*)$")
BANNER_RE = re.compile(r"##\s+(\d+):\s+")
SA_FAMILY_RE = re.compile(r"sa_family=(\w+)")
ODD_TOP_RE = re.compile(r"^(QR|qr|tmp|obj|bin|\.)")


def open_trace(path: str):
    with open(path, "rb") as probe:
        magic = probe.read(2)
    if path.endswith(".gz") or magic == b"\x1f\x8b":
        return gzip.open(path, "rt", encoding="latin-1", errors="replace")
    return open(path, "rt", encoding="latin-1", errors="replace")


def parse_makefile(mk_path: str) -> list[tuple[str, str]]:
    rules: list[tuple[str, str]] = []
    with open(mk_path, encoding="latin-1") as fh:
        for line in fh:
            m = RULE_RE.match(line)
            if m:
                rules.append((m.group(1), m.group(2)))
    return rules


def normalize_path(pid: int, raw_path: str, cwd: dict[int, str], root_dir: str) -> str:
    if not raw_path.startswith("/"):
        raw_path = cwd.get(pid, root_dir) + "/" + raw_path
    parts: list[str] = []
    for seg in raw_path.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if parts:
                parts.pop()
        else:
            parts.append(seg)
    return "/" + "/".join(parts)


def rel_to_root(abs_path: str, root_dir: str) -> str | None:
    if abs_path == root_dir:
        return "."
    prefix = root_dir + "/"
    return abs_path[len(prefix) :] if abs_path.startswith(prefix) else None


def summarize_net_args(args: str, ret: str, tail: str) -> str:
    detail = re.sub(r"\s+", " ", args).strip()
    if len(detail) > 120:
        detail = detail[:117] + "..."
    status = ret + (tail.strip() and (" " + tail.strip()) or "")
    return f"ret={status} {detail}".strip()


def audit_trace(trace_path: str, makefile_path: str, root_dir: str) -> dict:
    root_dir = root_dir.rstrip("/") or "/"
    rules = parse_makefile(makefile_path)
    inp = {i + 1: r[1] for i, r in enumerate(rules)}

    parent: dict[int, int] = {}
    cwd: dict[int, str] = {}
    step_of: dict[int, int] = {}
    unfinished: dict[int, str] = {}

    root_pid: int | None = None
    cur_step = 0
    written: dict[str, set[int]] = collections.defaultdict(set)
    findings: list[tuple[int, str, str, str]] = []
    procs: collections.Counter[tuple[int, str]] = collections.Counter()
    dirs: collections.Counter[tuple[int, str]] = collections.Counter()

    with open_trace(trace_path) as fh:
        for raw in fh:
            m = LINE_RE.match(raw.rstrip("\n"))
            if not m:
                continue
            pid = int(m.group(1) or m.group(2))
            rest = m.group(3)
            if rest.endswith("<unfinished ...>"):
                unfinished[pid] = rest[: -len("<unfinished ...>")].rstrip()
                continue
            resumed = RESUMED_RE.match(rest)
            if resumed:
                rest = unfinished.pop(pid, resumed.group(1) + "(") + resumed.group(2)
            call = CALL_RE.match(rest)
            if not call:
                continue
            name, args, ret, tail = call.group(1), call.group(2), call.group(3), call.group(4)

            if root_pid is None:
                root_pid = pid
                cwd[pid] = root_dir
                step_of[pid] = 0

            if name in ("clone", "clone3", "fork", "vfork") and ret.isdigit() and int(ret) > 0:
                child = int(ret)
                parent[child] = pid
                cwd[child] = cwd.get(pid, root_dir)
                step_of[child] = step_of.get(pid, cur_step)
                continue

            if name == "chdir" and ret == "0":
                cm = re.search(r'"([^"]*)"', args)
                if cm:
                    cwd[pid] = normalize_path(pid, cm.group(1), cwd, root_dir)
                continue

            if name in ("execve", "execveat"):
                if parent.get(pid) == root_pid:
                    banner = BANNER_RE.search(args)
                    if banner:
                        cur_step = int(banner.group(1))
                    step_of[pid] = cur_step
                continue

            st = step_of.get(pid, cur_step)

            if name in ("open", "openat", "openat2", "creat"):
                pm = re.search(r'"([^"]*)"', args)
                if not pm or not ret.lstrip("-").isdigit() or int(ret) < 0:
                    continue
                abs_p = normalize_path(pid, pm.group(1), cwd, root_dir)
                rp = rel_to_root(abs_p, root_dir)
                if abs_p.startswith("/proc/"):
                    procs[(st, re.sub(r"/proc/\d+", "/proc/<pid>", abs_p))] += 1
                if rp is None:
                    continue
                if "O_DIRECTORY" in args:
                    dirs[(st, rp)] += 1
                    continue
                is_write = (
                    name == "creat"
                    or "O_WRONLY" in args
                    or "O_RDWR" in args
                    or "O_CREAT" in args
                )
                if is_write:
                    written[rp].add(st)
                    top = rp.split("/")[0]
                    if st and not rp.startswith("vendor/") and not ODD_TOP_RE.match(top) and pid != root_pid:
                        findings.append((st, "WRITE-ODD", rp, ""))
                    continue
                if st == 0 or pid == root_pid:
                    continue
                if rp == inp.get(st) or rp.startswith("vendor/"):
                    continue
                if st in written.get(rp, ()):
                    continue
                who = ",".join(str(s) for s in sorted(written.get(rp, ()))) or "pre-existing"
                findings.append((st, "READ-FOREIGN", rp, "written by step " + who))

            elif name in ("rename", "renameat", "renameat2", "link", "linkat", "symlink", "symlinkat"):
                paths = re.findall(r'"([^"]*)"', args)
                if paths and ret == "0":
                    dst = rel_to_root(normalize_path(pid, paths[-1], cwd, root_dir), root_dir)
                    if dst:
                        written[dst].add(st)
                    desc = " -> ".join(
                        rel_to_root(normalize_path(pid, x, cwd, root_dir), root_dir) or x
                        for x in paths
                    )
                    findings.append((st, "RENAME", desc, ""))

            elif name in ("connect", "sendto", "sendmsg"):
                fm = SA_FAMILY_RE.search(args)
                if fm:
                    fam = fm.group(1)
                    if fam not in ("AF_UNIX", "AF_UNSPEC"):
                        findings.append((st, "NET", fam, summarize_net_args(args, ret, tail)))

    unique_findings: list[tuple[int, str, str, str]] = []
    seen: set[tuple[int, str, str, str]] = set()
    for item in findings:
        if item not in seen:
            seen.add(item)
            unique_findings.append(item)

    return {
        "steps_seen": cur_step,
        "rules": len(rules),
        "findings": unique_findings,
        "dirs": dirs,
        "procs": procs,
    }


def write_tsv(result: dict, out_path: str) -> None:
    close_out = False
    if out_path == "-":
        out_fh = sys.stdout
    else:
        out_fh = open(out_path, "w", encoding="utf-8", newline="\n")
        close_out = True
    try:
        out_fh.write("step\tkind\tfile\tnote\n")
        for row in result["findings"]:
            out_fh.write("\t".join(map(str, row)) + "\n")
        out_fh.write("\n# relay-dir directory listings per step (informational)\n")
        for (step, path), count in sorted(result["dirs"].items()):
            out_fh.write(f"{step}\tDIR\t{path}\t{count}\n")
        out_fh.write("\n# /proc opens per step (informational; runtimes do this)\n")
        for (step, path), count in sorted(result["procs"].items()):
            out_fh.write(f"{step}\tPROC\t{path}\t{count}\n")
    finally:
        if close_out:
            out_fh.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audit strace logs of Quine Relay 256 `make all` runs."
    )
    parser.add_argument("trace", help="Path to strace -f output (.txt or .txt.gz)")
    parser.add_argument("makefile", help="Path to Makefile")
    parser.add_argument(
        "out",
        nargs="?",
        default="-",
        help="Output TSV path (default: '-' for stdout)",
    )
    parser.add_argument(
        "--root",
        default=DEFAULT_ROOT,
        help=f"Relay working directory inside traced environment (default: {DEFAULT_ROOT})",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit 2 if any READ-FOREIGN, WRITE-ODD, or NET findings occur",
    )
    parser.add_argument(
        "--strict-net",
        action="store_true",
        help="Exit 2 if any non-Unix socket (NET) findings occur",
    )
    args = parser.parse_args(argv)

    result = audit_trace(args.trace, args.makefile, args.root)
    write_tsv(result, args.out)

    counts = collections.Counter(row[1] for row in result["findings"])
    n_rf = counts["READ-FOREIGN"]
    n_wo = counts["WRITE-ODD"]
    n_net = counts["NET"]
    summary = (
        f"steps seen {result['steps_seen']} rules {result['rules']} "
        f"findings {len(result['findings'])} "
        f"(read_foreign={n_rf} write_odd={n_wo} rename={counts['RENAME']} net={n_net})"
    )
    stream = sys.stderr if args.out == "-" else sys.stdout
    print(summary, file=stream)

    if args.strict and (n_rf + n_wo + n_net) > 0:
        return 2
    if args.strict_net and n_net > 0:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
