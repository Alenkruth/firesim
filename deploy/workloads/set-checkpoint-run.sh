#!/usr/bin/env bash
# set-checkpoint-run.sh — Point a checkpoint workload JSON and runtime config
# at a specific simpoint.
#
# Usage: ./set-checkpoint-run.sh <name> <mem_elf> <loadarch> [runtime_cfg] [workload_json]
#
#   runtime_cfg   : YAML to patch +loadmem/+loadarch into
#                   (default: config_runtime_checkpoint.yaml — FPGA 1)
#   workload_json : workload JSON to set benchmark_name in
#                   (default: workloads/checkpoint-run.json)
# Pass the FPGA-0 pair (config_runtime_checkpoint_0.yaml + checkpoint-run_0.json) to
# drive FPGA 0 concurrently with FPGA 1 without clobbering the other's files.

set -eo pipefail

NAME="$1"
MEM_ELF="$2"
LOADARCH_FILE="$3"
RUNTIME_CFG_ARG="$4"
JSON_ARG="$5"

if [[ -z "$NAME" || -z "$MEM_ELF" || -z "$LOADARCH_FILE" ]]; then
    echo "Usage: $0 <name> <mem_elf> <loadarch> [runtime_cfg] [workload_json]" >&2
    exit 1
fi

# Mode-2 UART-fix override: if a patched mem.elf exists for this checkpoint, use it.
# The patch redirects OpenSBI's ns16550 console base off the unmapped physical
# 0x10000000 to a loaded scratch page (LSR=0x60), so the SBI-console read no longer
# faults and the re-entrant sbi_trap_error console-lock deadlock never forms.
# Source images are untouched; only the loaded image is swapped.
_ckrel="$(echo "$MEM_ELF" | sed -n 's#.*/checkpoints/\(.*\)/mem.elf$#\1#p')"
_patched="/data/akrish/scratch/uart-patched/${_ckrel}/mem.elf"
if [[ -n "$_ckrel" && -f "$_patched" ]]; then
    echo "  [uart-fix] using patched mem.elf for ${_ckrel}"
    MEM_ELF="$_patched"
fi

if [[ ! -f "$MEM_ELF" ]]; then
    echo "ERROR: mem.elf not found: $MEM_ELF" >&2
    exit 1
fi

if [[ ! -f "$LOADARCH_FILE" ]]; then
    echo "ERROR: loadarch not found: $LOADARCH_FILE" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JSON="${JSON_ARG:-$SCRIPT_DIR/checkpoint-run.json}"
RUNTIME_CFG="${RUNTIME_CFG_ARG:-$DEPLOY_DIR/config_runtime_checkpoint.yaml}"
if [[ ! -f "$JSON" ]]; then echo "ERROR: workload JSON not found: $JSON" >&2; exit 1; fi
if [[ ! -f "$RUNTIME_CFG" ]]; then echo "ERROR: runtime config not found: $RUNTIME_CFG" >&2; exit 1; fi
WORKLOAD_DIR="$SCRIPT_DIR/$NAME"
MEM_ELF_ABS="$(realpath "$MEM_ELF")"
LOADARCH_ABS="$(realpath "$LOADARCH_FILE")"

# Workload dir: boot.riscv -> mem.elf, so FESVR resolves tohost/fromhost symbols
# (fesvr/htif.cc:179) and CAN service HTIF.
#   These checkpoints are HTIF syscall-proxy binaries: any trap that reaches M-mode
#   vectors to mtvec (the pk/bbl HTIF service routine) and needs FESVR to respond.
#   Pointing boot.riscv at a symbol-less stub makes htif.cc:269 take the idle() path,
#   so FESVR never answers and the target spins forever at mtvec. Do NOT do that.
# The real hazard is TIMING, handled via +fesvr-wait-ticks (see config_runtime_checkpoint.yaml):
#   FESVR must not service HTIF until the loadarch restore completes (~163k cycles),
#   otherwise it reads garbage written by the pre-restore cold boot and aborts with
#   "bad syscall #0". wait_ticks * step_size must exceed the restore window.
# CORRECTED 2026-07-22: the line below USED to claim boot.riscv is symbol-resolution only.
# That is FALSE and cost several debug runs. testchip_dtm.h:75-78 overrides load_program():
#     void load_program() { is_loadmem = has_loadmem; dtm_t::load_program(); is_loadmem = false; }
# htif_t::start() calls it, so FESVR loads boot.riscv INTO DRAM over the XDMA loadmem path --
# fast and silent (no log line, no measurable wallclock) -- and it runs AFTER init_dram()'s
# +loadmem. boot.riscv therefore WINS. If boot.riscv and +loadmem differ, +loadmem is discarded.
# KEEP THEM THE SAME FILE.
# NOTE: DRAM loading is via +loadmem= (MIDAS simulation_t XDMA path) AND via boot.riscv/FESVR.
#   set_loaded_in_target(true) only unblocks firesim_dtm_t::reset()'s wait loop; it does NOT
#   suppress load_program(). htif_t::start() calls load_program() THEN reset(), unconditionally
#   (targs[0] != "none"). boot.riscv supplies tohost/fromhost symbols AND the DRAM contents.
mkdir -p "$WORKLOAD_DIR"
ln -sf "$MEM_ELF_ABS" "$WORKLOAD_DIR/boot.riscv"

# Update checkpoint-run.json benchmark_name
python3 - "$NAME" "$JSON" <<'PYEOF'
import json, sys
name, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d['benchmark_name'] = name
d['common_bootbinary'] = "boot.riscv"
json.dump(d, open(path, 'w'), indent=2)
PYEOF

# Patch +loadmem= and +loadarch= in plusarg_passthrough, preserving all other plusargs.
sed -i "s|+loadmem=[^ \"]*|+loadmem=${MEM_ELF_ABS}|" "$RUNTIME_CFG"
sed -i "s|+loadarch=[^ \"]*|+loadarch=${LOADARCH_ABS}|" "$RUNTIME_CFG"

echo "[set-checkpoint-run]"
echo "  name      : $NAME"
echo "  loadmem   : $MEM_ELF_ABS"
echo "  loadarch  : $LOADARCH_ABS"
echo "  cfg       : $RUNTIME_CFG"
echo "  json      : $JSON"
