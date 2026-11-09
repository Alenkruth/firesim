#!/usr/bin/env bash
# run_checkpoints_parallel.sh — Run a benchmark's SimPoint checkpoints split across
# BOTH Alveo U250 FPGAs concurrently, then merge into one weighted-IPC summary.
#
#   FPGA 1 (config_runtime_checkpoint.yaml,   db-1 3b:00.0, sim-1) -> shard 0/2 (even sp)
#   FPGA 0 (config_runtime_checkpoint_0.yaml, db-0 5e:00.0, sim)   -> shard 1/2 (odd  sp)
# Both flash the same Sv57 bitstream; each has its own runtime YAML + workload JSON,
# so the two set-checkpoint-run.sh patchers never touch the same file.
#
# Usage:
#   bash deploy/workloads/run_checkpoints_parallel.sh [BENCH] [BASE_DIR]
#     BENCH    default 605.mcf_s
#     BASE_DIR default /data/akrish/checkpoints/spec17-intspeed-fullsys-spike
#
# NOTE: validate ONE checkpoint single-FPGA first (see the go/no-go run) before
#       committing both FPGAs to a full sweep.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUITE="$SCRIPT_DIR/run_checkpoint_suite.sh"

BENCH="${1:-605.mcf_s}"
BASE_DIR="${2:-/data/akrish/checkpoints/spec17-intspeed-fullsys-spike}"

TS="$(date +%Y-%m-%d--%H-%M-%S)"
LOGDIR="/data/akrish/firesim/checkpoint-suite-results/parallel-$TS-$BENCH"
mkdir -p "$LOGDIR"

echo "=== Parallel checkpoint sweep: $BENCH ==="
echo "  base    : $BASE_DIR"
echo "  logs    : $LOGDIR"
echo "  FPGA 1  : config_runtime_checkpoint.yaml   shard 0/2 (even sp)"
echo "  FPGA 0  : config_runtime_checkpoint_0.yaml shard 1/2 (odd  sp)"
echo ""

cd "$DEPLOY_DIR"

# FPGA 1 — even simpoints
bash "$SUITE" --config config_runtime_checkpoint.yaml \
    --bench "$BENCH" --shard 0/2 "$BASE_DIR" > "$LOGDIR/fpga1.log" 2>&1 &
PID1=$!
echo "  launched FPGA 1 (pid $PID1)"

# small stagger so the two initial FPGA programmings don't start in the exact same instant
sleep 8

# FPGA 0 — odd simpoints
bash "$SUITE" --config config_runtime_checkpoint_0.yaml \
    --bench "$BENCH" --shard 1/2 "$BASE_DIR" > "$LOGDIR/fpga0.log" 2>&1 &
PID0=$!
echo "  launched FPGA 0 (pid $PID0)"
echo ""

RC1=0; RC0=0
wait "$PID1" || RC1=$?
echo "  FPGA 1 finished (rc=$RC1)"
wait "$PID0" || RC0=$?
echo "  FPGA 0 finished (rc=$RC0)"
echo ""

SUM1="$(grep -oE '/data/akrish/firesim/checkpoint-suite-results/[^ ]*/summary.csv' "$LOGDIR/fpga1.log" | tail -1 || true)"
SUM0="$(grep -oE '/data/akrish/firesim/checkpoint-suite-results/[^ ]*/summary.csv' "$LOGDIR/fpga0.log" | tail -1 || true)"
echo "  FPGA 1 summary: ${SUM1:-<none>}"
echo "  FPGA 0 summary: ${SUM0:-<none>}"

MERGED="$LOGDIR/summary-merged.csv"
python3 - "$MERGED" "$SUM1" "$SUM0" <<'PYEOF'
import sys, csv, os
from collections import defaultdict

merged_path = sys.argv[1]
srcs = [p for p in sys.argv[2:] if p and os.path.isfile(p)]

rows, header = [], None
for p in srcs:
    with open(p) as f:
        r = csv.reader(f)
        h = next(r, None)
        if h is None:
            continue
        header = h
        for line in r:
            if line:
                rows.append(line)

if header is None:
    print("\n  no summaries to merge"); sys.exit(0)

# sort by benchmark then numeric simpoint index for a stable table
def spidx(v):
    try: return int(v.replace('sp_', ''))
    except ValueError: return 1<<30
rows.sort(key=lambda x: (x[0], spidx(x[1])))

with open(merged_path, 'w', newline='') as f:
    w = csv.writer(f); w.writerow(header); w.writerows(rows)

idx = {name: i for i, name in enumerate(header)}
print("\n--- Merged per-simpoint IPC ---")
print(f"  {'simpoint':12s} {'weight':>8s} {'IPC':>8s}  status")
data = defaultdict(list)
for x in rows:
    bench, sp, weight, ipc, status = x[idx['benchmark']], x[idx['simpoint']], x[idx['weight']], x[idx['ipc']], x[idx['status']]
    flag = '' if status == 'OK' else f'  <-- {status}'
    print(f"  {sp:12s} {weight:>8s} {ipc:>8s}  {status}{flag}")
    if status == 'OK' and ipc not in ('', 'N/A'):
        try: data[bench].append((float(weight), float(ipc)))
        except ValueError: pass

print("\n--- Weighted IPC ---")
for bench in sorted(data):
    e = data[bench]; tw = sum(w for w, _ in e)
    if tw < 1e-9: continue
    wipc = sum(w*i for w, i in e)/tw
    print(f"  {bench:20s} weighted_IPC={wipc:.4f}  ({len(e)} sp, {round(100*tw,1)}% coverage)")
print(f"\n  merged CSV: {merged_path}")
PYEOF

echo ""
echo "=== done (FPGA1 rc=$RC1, FPGA0 rc=$RC0) ==="