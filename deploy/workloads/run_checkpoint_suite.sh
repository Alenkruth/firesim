#!/usr/bin/env bash
# run_checkpoint_suite.sh — Sequential sweep of SPEC2017 SimPoint checkpoints on FireSim.
#
# IPC and stall breakdown are derived entirely from AutoCounter (no TracerV).
# AutoCounter samples at 1M cycles; warmup/measure windows are defined by
# instruction commit counts, giving sub-0.5% cycle uncertainty.
#
# Usage:
#   bash deploy/workloads/run_checkpoint_suite.sh [options] [BASE_DIR]
#
#   -n / --dry-run       Print what would run without touching FireSim or configs
#   --config <yaml>      Runtime config basename under deploy/ to drive
#                        (default config_runtime_checkpoint.yaml = FPGA 1;
#                         use config_runtime_checkpoint_0.yaml for FPGA 0).
#                        The workload JSON is auto-derived from its workload_name.
#   --bench <name>       Only run this benchmark (e.g. 605.mcf_s)
#   --shard <i/n>        Only run simpoints whose index%n==i (0-based). Two
#                        instances with 0/2 and 1/2 split a bench across 2 FPGAs.
#   -h / --help          Show this message
#
# BASE_DIR defaults to /data/akrish/checkpoints/intspeed-nowarmup
#   checkpoints : BASE_DIR/checkpoints/<bench>/sp_<N>/{mem.elf,loadarch}
#   sp weights  : BASE_DIR/simpoints/<bench>.weights  (format: "<weight> <cluster_id>" per line)
#
# Per-checkpoint flow:
#   set-checkpoint-run.sh → patches config_runtime_checkpoint.yaml (+loadarch, +max-cycles)
#   firesim infrasetup    → rsyncs boot.riscv (mem.elf symlink); skips FPGA reflash
#   firesim runworkload   → collects AUTOCOUNTERFILE0.csv
#
# Windowing (post-hoc, in autocounter_ipc): 50M-insn warmup then 100M-insn measure
# => ~150M insns analyzed past restore; at IPC~0.2 that's ~750M cycles, so max-cycles=2B is ample.
# NOTE: +max-cycles uses a 32-bit counter in FESVR; values >4294967295 silently overflow.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_CFG="config_runtime_checkpoint.yaml"

WARMUP_INSNS=50000000   # 50M instructions: warm L1s + branch predictor after restore
MEASURE_INSNS=100000000 # 100M instructions: full SimPoint interval
MAX_CYCLES=2000000000   # 2B cycles: below signed 32-bit max (atoi in deployed driver); mcf_s needs ~1444M

DRY_RUN=0
BASE_DIR="/data/akrish/checkpoints/spec17-intspeed-fullsys-spike"
BENCH_FILTER=""     # if set, only run this benchmark (e.g. 605.mcf_s)
SHARD_I=""          # shard index i (with --shard i/n): run sp where idx%n==i
SHARD_N=""          # shard count n

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)  DRY_RUN=1; shift ;;
        --config)      RUNTIME_CFG="$2"; shift 2 ;;
        --bench)       BENCH_FILTER="$2"; shift 2 ;;
        --shard)       SHARD_I="${2%%/*}"; SHARD_N="${2##*/}"; shift 2 ;;
        -h|--help)     usage ;;
        *)             BASE_DIR="$1"; shift ;;
    esac
done

CHECKPOINT_BASE="$BASE_DIR/checkpoints"
SIMPOINTS_BASE="$BASE_DIR/simpoints"

# Derive the workload JSON from the chosen runtime config's workload_name, so the
# per-simpoint patcher edits the SAME JSON this config actually loads.
WL_JSON_NAME="$(grep -E '^[[:space:]]*workload_name:' "$DEPLOY_DIR/$RUNTIME_CFG" | awk '{print $2}')"
WL_JSON="$SCRIPT_DIR/$WL_JSON_NAME"
CFG_LABEL="$(basename "$RUNTIME_CFG" .yaml)"

SUITE_TS="$(date +%Y-%m-%d--%H-%M-%S)"
# Tag results with the config label so two concurrent instances (FPGA 0 / FPGA 1)
# launched in the same second do not share a results dir.
RESULTS_DIR="/data/akrish/firesim/checkpoint-suite-results/$SUITE_TS-$CFG_LABEL"
SUMMARY_CSV="$RESULTS_DIR/summary.csv"
SUITE_LOG="$RESULTS_DIR/suite.log"

[[ $DRY_RUN -eq 0 ]] && mkdir -p "$RESULTS_DIR"

log() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "$*"
    else
        echo "$*" | tee -a "$SUITE_LOG"
    fi
}

log "=== Checkpoint Suite $([ $DRY_RUN -eq 1 ] && echo '[DRY RUN]') ==="
log "Started    : $(date)"
log "Base       : $BASE_DIR"
log "Checkpoints: $CHECKPOINT_BASE"
log "Simpoints  : $SIMPOINTS_BASE"
log "Warmup     : ${WARMUP_INSNS} instructions"
log "Measure    : ${MEASURE_INSNS} instructions"
log "MaxCycles  : ${MAX_CYCLES}"
if [[ $DRY_RUN -eq 0 ]]; then log "Results    : $RESULTS_DIR"; fi
log ""

if [[ $DRY_RUN -eq 0 ]]; then
    echo "benchmark,simpoint,weight,ipc,fetch_stall_pct,rob_full_pct,dcache_miss_pct,br_mispredict_pct,icache_miss_pct,ldq_full_pct,stq_full_pct,mem_order_viol_pct,warmup_end_cycle,measure_end_cycle,status,result_dir" \
        > "$SUMMARY_CSV"
fi

# ---------------------------------------------------------------------------
# autocounter_ipc  <csv_path>
# Prints: ipc fetch_pct rob_pct dcache_pct br_pct icache_pct ldq_pct stq_pct memorder_pct
#         warmup_end_cycle measure_end_cycle
# ---------------------------------------------------------------------------
autocounter_ipc() {
python3 - "$1" "$WARMUP_INSNS" "$MEASURE_INSNS" <<'PYEOF'
import sys

csv_path     = sys.argv[1]
warmup_insns = int(sys.argv[2])
measure_insns = int(sys.argv[3])

FAIL = "N/A 0 0 0 0 0 0 0 0 N/A N/A"

with open(csv_path) as f:
    lines = f.readlines()

# Locate the header row instead of assuming a fixed offset. The metadata block is
# NOT a fixed 5 rows: observed CSVs carry 7 (version, clock-domain, label,
# description, type, event width, accumulator width). The old code read lines[5:]
# and only survived because the extra metadata rows happened to fail int() and get
# swallowed by the except. Any change to the metadata block would silently shift the
# parse and yield a wrong IPC rather than an error.
hdr_idx = next((i for i, l in enumerate(lines)
                if l.split(',')[0].strip().strip('"').lower() == 'label'), None)
if hdr_idx is None:
    print(FAIL + " (no 'label' header row in AutoCounter CSV)"); sys.exit()

headers = lines[hdr_idx].strip().split(',')
short   = {h: h.split('BOOM_v3_')[-1] if 'BOOM_v3_' in h else h for h in headers}

if 'local_cycle' not in short.values():
    print(FAIL + " (AutoCounter CSV has no local_cycle column)"); sys.exit()

# A data row has exactly len(headers) fields and every field is an integer.
# Metadata rows (description/type/width) fail on both counts, so they're rejected
# explicitly rather than by accident.
data = []
for line in lines[hdr_idx + 1:]:
    parts = line.strip().split(',')
    if len(parts) != len(headers):
        continue
    try:
        values = [int(v) for v in parts]
    except ValueError:
        continue
    data.append(dict(zip((short[h] for h in headers), values)))

if not data:
    print(FAIL + " (no numeric sample rows; sim likely aborted before first sample)")
    sys.exit()

COMMIT_SLOTS = ['CommitSlot0', 'CommitSlot1', 'CommitSlot2', 'CommitSlot3']
def commits(r): return sum(r.get(c, 0) for c in COMMIT_SLOTS)

# Find restore point: first row with any committed instructions
r_restore = next((r for r in data if commits(r) > 0), None)
if r_restore is None:
    print(FAIL); sys.exit()

base = commits(r_restore)

# Warmup end: cumulative commits from restore >= warmup_insns
r_warmup = next((r for r in data if commits(r) - base >= warmup_insns), None)
if r_warmup is None:
    print(FAIL + " (warmup window not reached — increase max-cycles)"); sys.exit()

# Measure end: cumulative commits from restore >= warmup + measure
r_measure = next((r for r in data if commits(r) - base >= warmup_insns + measure_insns), None)
if r_measure is None:
    print(FAIL + " (measure window not reached — increase max-cycles)"); sys.exit()

dcycles = r_measure['local_cycle'] - r_warmup['local_cycle']
if dcycles <= 0:
    print(FAIL); sys.exit()

actual_commits = commits(r_measure) - commits(r_warmup)
ipc = round(actual_commits / dcycles, 4)

def pct(key):
    delta = r_measure.get(key, 0) - r_warmup.get(key, 0)
    return round(100.0 * delta / dcycles, 1)

print(ipc,
      pct('FetchStall'), pct('ROBFullStall'), pct('DCacheMiss'),
      pct('BrMispredict'), pct('ICacheMiss'),
      pct('LDQFullStall'), pct('STQFullStall'), pct('MemOrderViolation'),
      r_warmup['local_cycle'], r_measure['local_cycle'])
PYEOF
}

# ---------------------------------------------------------------------------
# load_weight <bench> <sp>
# Prints the SimPoint weight for this (bench, sp) pair, or "N/A" if not found.
# Looks for $SIMPOINTS_BASE/<bench>.weights (format: "<weight> <cluster_id>" per line).
# sp_N maps to cluster_id N.
# ---------------------------------------------------------------------------
load_weight() {
python3 - "$SIMPOINTS_BASE/$1.weights" "${2#sp_}" <<'PYEOF'
import sys, os

weights_file, sp_id = sys.argv[1], sys.argv[2]

if not os.path.isfile(weights_file):
    print('N/A'); sys.exit(0)

with open(weights_file) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) >= 2 and parts[1] == sp_id:
            print(parts[0]); sys.exit(0)

print('N/A')
PYEOF
}

# ---------------------------------------------------------------------------
# run_one <bench> <sp> <weight>
# ---------------------------------------------------------------------------
run_one() {
    local bench="$1" sp="$2" weight="$3"
    local sp_dir="$CHECKPOINT_BASE/$bench/$sp"
    local mem_elf="$sp_dir/mem.elf"
    local loadarch="$sp_dir/loadarch"
    local name="${bench}-${sp}"

    log ""
    log "--- [$name] (weight=${weight}) ---"

    if [[ ! -f "$mem_elf" ]]; then
        log "  SKIP: no mem.elf at $mem_elf"
        if [[ $DRY_RUN -eq 0 ]]; then echo "$bench,$sp,$weight,,,,,,,,,,,,MISSING," >> "$SUMMARY_CSV"; fi
        return 0
    fi
    if [[ ! -f "$loadarch" ]]; then
        log "  SKIP: no loadarch at $loadarch"
        if [[ $DRY_RUN -eq 0 ]]; then echo "$bench,$sp,$weight,,,,,,,,,,,,MISSING," >> "$SUMMARY_CSV"; fi
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "  mem.elf  : $mem_elf"
        log "  loadarch : $loadarch"
        log "  [would run: set-checkpoint-run.sh -> infrasetup -> runworkload]"
        return 0
    fi

    cd "$DEPLOY_DIR"

    bash "$SCRIPT_DIR/set-checkpoint-run.sh" "$name" "$mem_elf" "$loadarch" \
        "$DEPLOY_DIR/$RUNTIME_CFG" "$WL_JSON" >> "$SUITE_LOG" 2>&1
    sed -i "s|+max-cycles=[0-9]*|+max-cycles=${MAX_CYCLES}|" "$RUNTIME_CFG"

    if ! firesim -c "$RUNTIME_CFG" infrasetup >> "$SUITE_LOG" 2>&1; then
        log "  ERROR: infrasetup failed"
        echo "$bench,$sp,$weight,,,,,,,,,,,,INFRA_FAIL," >> "$SUMMARY_CSV"
        return 0
    fi

    if ! firesim -c "$RUNTIME_CFG" runworkload >> "$SUITE_LOG" 2>&1; then
        log "  ERROR: runworkload failed"
        echo "$bench,$sp,$weight,,,,,,,,,,,,RUN_FAIL," >> "$SUMMARY_CSV"
        return 0
    fi

    # Find the result directory for this run
    local result_dir
    result_dir=$(ls -dt "$DEPLOY_DIR/results-workload/"????-??-??--??-??-??-"$name"/ \
        2>/dev/null | head -1 || true)

    if [[ -z "$result_dir" ]]; then
        log "  ERROR: result directory not found"
        echo "$bench,$sp,$weight,,,,,,,,,,,,NO_RESULT," >> "$SUMMARY_CSV"
        return 0
    fi

    local autocounter="$result_dir/${name}0/AUTOCOUNTERFILE0.csv"

    if [[ ! -f "$autocounter" ]]; then
        log "  ERROR: AutoCounter CSV not found at $autocounter"
        echo "$bench,$sp,$weight,,,,,,,,,,,,NO_AUTOCOUNTER,$result_dir" >> "$SUMMARY_CSV"
        return 0
    fi

    local stats
    stats=$(autocounter_ipc "$autocounter" 2>>"$SUITE_LOG") || true
    read -r ipc fetch_pct rob_pct dcache_pct br_pct icache_pct \
             ldq_pct stq_pct mem_order_pct warmup_cyc measure_cyc <<< "$stats"

    if [[ -z "$ipc" || "$ipc" == "N/A" ]]; then
        log "  ERROR: AutoCounter parse failed (IPC=N/A)"
        echo "$bench,$sp,$weight,,,,,,,,,,,,IPC_FAIL,$result_dir" >> "$SUMMARY_CSV"
        return 0
    fi

    log "  IPC=${ipc}  FetchStall=${fetch_pct}% ROBFull=${rob_pct}% DCacheMiss=${dcache_pct}% BrMispredict=${br_pct}%"
    echo "$bench,$sp,$weight,$ipc,$fetch_pct,$rob_pct,$dcache_pct,$br_pct,$icache_pct,$ldq_pct,$stq_pct,$mem_order_pct,$warmup_cyc,$measure_cyc,OK,$result_dir" \
        >> "$SUMMARY_CSV"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
total=0

for bench_dir in "$CHECKPOINT_BASE"/*/; do
    [[ -d "$bench_dir" ]] || continue
    bench=$(basename "$bench_dir")
    # skip non-benchmark dirs (e.g. logs/)
    [[ "$bench" =~ ^[0-9] ]] || continue
    # optional single-benchmark restriction (--bench)
    [[ -n "$BENCH_FILTER" && "$bench" != "$BENCH_FILTER" ]] && continue

    found_sp=0
    sp_idx=-1
    for sp_dir in "$bench_dir"sp_*/; do
        [[ -d "$sp_dir" ]] || continue
        (( sp_idx++ )) || true
        # optional shard split (--shard i/n): both FPGAs enumerate sp_* in the
        # same sorted order, so idx%n gives a disjoint, complete partition.
        if [[ -n "$SHARD_N" ]] && (( sp_idx % SHARD_N != SHARD_I )); then
            continue
        fi
        found_sp=1
        sp=$(basename "$sp_dir")
        weight=$(load_weight "$bench" "$sp")
        run_one "$bench" "$sp" "$weight"
        (( total++ )) || true
    done

    [[ $found_sp -eq 0 ]] && log "  (no sp_* dirs under $bench for this shard, skipping)"
done

log ""
log "=== Suite $([ $DRY_RUN -eq 1 ] && echo 'dry run') complete ==="
log "Finished  : $(date)"
log "Processed : $total checkpoints"
if [[ $DRY_RUN -eq 0 ]]; then log "Summary   : $SUMMARY_CSV"; fi

# ---------------------------------------------------------------------------
# Weighted IPC summary — printed after real runs only
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 0 && -f "$SUMMARY_CSV" ]]; then
python3 - "$SUMMARY_CSV" "$SUITE_LOG" <<'PYEOF'
import sys, csv
from collections import defaultdict

csv_path, log_path = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(csv_path)))

bench_data = defaultdict(list)
for r in rows:
    if r['status'] == 'OK' and r['ipc'] not in ('N/A', ''):
        try:
            bench_data[r['benchmark']].append((float(r['weight']), float(r['ipc'])))
        except ValueError:
            pass

if not bench_data:
    sys.exit(0)

lines = ['\n--- Weighted IPC Summary ---']
for bench in sorted(bench_data):
    entries = bench_data[bench]
    total_w = sum(w for w, _ in entries)
    if total_w < 1e-9:
        continue
    wipc = sum(w * ipc for w, ipc in entries) / total_w
    coverage = round(100.0 * total_w, 1)
    lines.append(f'  {bench:35s}  weighted_IPC={wipc:.4f}  ({len(entries)} sp, {coverage}% coverage)')

output = '\n'.join(lines)
print(output)
with open(log_path, 'a') as f:
    f.write(output + '\n')
PYEOF
fi
