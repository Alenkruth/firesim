#!/usr/bin/env python3
# fullbench_ipc.py — compute IPC from a full-benchmark FireSim run.
#
# Usage:
#   python3 fullbench_ipc.py <AUTOCOUNTERFILE0.csv> [<uartlog>]
#
# AutoCounter is sampled every 1M cycles.  IPC is measured over three windows:
#   total  — entire simulation (includes Linux boot)
#   bench  — from first row where cumulative commits exceed BOOT_INSNS_THRESHOLD
#             to the last row with non-zero commits (approximates post-boot execution)
#   If a uartlog is supplied, a "uartlog" note is printed but cycle-accurate
#   BENCH_STARTED correlation is not attempted (UART has no cycle timestamps).
#
# Output (space-separated, one line):
#   ipc_total  ipc_bench  total_cycles  bench_cycles  total_commits  bench_commits  status

import sys
import os

# Instructions committed during Linux boot (rough threshold to skip boot phase).
# Adjust down if benchmarks are short; perlbench runs >> 10B insns post-boot.
BOOT_INSNS_THRESHOLD = 2_000_000_000   # 2B instructions covers boot + init

COMMIT_SLOTS = ['CommitSlot0', 'CommitSlot1', 'CommitSlot2', 'CommitSlot3']

def commits(row):
    return sum(row.get(c, 0) for c in COMMIT_SLOTS)

def parse_csv(path):
    with open(path) as f:
        lines = f.readlines()
    # Row layout: 0=version, 1=clock-domain, 2=labels, 3=descriptions, 4=types, 5+=data
    headers = lines[2].strip().split(',')
    short = {h: h.split('BOOM_v3_')[-1] if 'BOOM_v3_' in h else h for h in headers}
    data = []
    for line in lines[5:]:
        parts = line.strip().split(',')
        if len(parts) < 2:
            continue
        try:
            row = {short[h]: int(v) for h, v in zip(headers, parts)}
            data.append(row)
        except (ValueError, KeyError):
            continue
    return data

def ipc_window(data, start_row, end_row):
    dcycles = end_row['local_cycle'] - start_row['local_cycle']
    dcommits = commits(end_row) - commits(start_row)
    if dcycles <= 0:
        return None, dcycles, dcommits
    return round(dcommits / dcycles, 4), dcycles, dcommits

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <AUTOCOUNTERFILE0.csv> [<uartlog>]", file=sys.stderr)
        sys.exit(1)

    csv_path = sys.argv[1]
    uartlog = sys.argv[2] if len(sys.argv) > 2 else None

    data = parse_csv(csv_path)
    if not data:
        print("N/A N/A 0 0 0 0 NO_DATA")
        sys.exit(0)

    # First and last rows with any commits
    r_first = next((r for r in data if commits(r) > 0), None)
    r_last  = next((r for r in reversed(data) if commits(r) > 0), None)

    if r_first is None or r_last is None or r_first is r_last:
        print("N/A N/A 0 0 0 0 INSUFFICIENT_DATA")
        sys.exit(0)

    ipc_total, total_cycles, total_commits = ipc_window(data, r_first, r_last)

    # Post-boot window: find the first row where cumulative commits cross BOOT_INSNS_THRESHOLD
    base_commits = commits(r_first)
    r_bench_start = next(
        (r for r in data if commits(r) - base_commits >= BOOT_INSNS_THRESHOLD),
        None
    )

    if r_bench_start is None:
        # Benchmark finished before threshold — entire run is shorter than expected
        ipc_bench, bench_cycles, bench_commits = ipc_total, total_cycles, total_commits
        status = "BOOT_THRESHOLD_NOT_REACHED"
    else:
        ipc_bench, bench_cycles, bench_commits = ipc_window(data, r_bench_start, r_last)
        status = "OK"

    print(ipc_total, ipc_bench, total_cycles, bench_cycles, total_commits, bench_commits, status)

    if uartlog and os.path.isfile(uartlog):
        with open(uartlog) as f:
            uart = f.read()
        if "BENCH_STARTED" in uart and "BENCH_EXIT_CODE" in uart:
            import re
            m = re.search(r'BENCH_EXIT_CODE=(\d+)', uart)
            rc = m.group(1) if m else "?"
            print(f"# UART: BENCH_STARTED found, exit code={rc}", file=sys.stderr)
        elif "BENCH_STARTED" not in uart:
            print("# UART: BENCH_STARTED not found — benchmark may not have started", file=sys.stderr)
        else:
            print("# UART: BENCH_STARTED found but no BENCH_EXIT_CODE — benchmark may not have finished", file=sys.stderr)

if __name__ == "__main__":
    main()
