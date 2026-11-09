#!/bin/bash
# set-ift-run.sh — Update ift-run.json before each FireSim test run.
#
# Usage: ./set-ift-run.sh <benchmark_name> <absolute_elf_path>
#
# Examples:
#   ./set-ift-run.sh ift-hello /home/jht9sy/work/chipyard/sims/verilator/base-attacks/boom-attacks/bin/hello.riscv
#   ./set-ift-run.sh ift-t01 /home/jht9sy/work/chipyard/sims/verilator/base-attacks/ift-tests/bin/t01_opcount.riscv
#   ./set-ift-run.sh ift-attack-ff /home/jht9sy/work/chipyard/sims/verilator/base-attacks/ff/binrv/ff_ift.riscv
#
# The benchmark_name controls the results-workload subdirectory name so successive
# runs don't overwrite each other.
#
# FireSim resolves common_bootbinary relative to workloads/<benchmark_name>/.
# This script creates that directory and symlinks the ELF there as "boot.riscv".
# rsync uses -L (follow symlinks) so the actual ELF content is copied to the host.

set -e
NAME=$1
ELF=$2

if [ -z "$NAME" ] || [ -z "$ELF" ]; then
    echo "Usage: $0 <benchmark_name> <absolute_elf_path>" >&2
    exit 1
fi

if [ ! -f "$ELF" ]; then
    echo "ERROR: ELF not found: $ELF" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JSON="$SCRIPT_DIR/ift-run.json"
WORKLOAD_DIR="$SCRIPT_DIR/$NAME"

# Create workload dir and symlink ELF as boot.riscv
mkdir -p "$WORKLOAD_DIR"
ln -sf "$ELF" "$WORKLOAD_DIR/boot.riscv"

python3 - "$NAME" "$JSON" <<'PYEOF'
import json, sys
name, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d['benchmark_name'] = name
d['common_bootbinary'] = 'boot.riscv'
json.dump(d, open(path, 'w'), indent=2)
print(f"[set-ift-run] {path}")
print(f"  benchmark_name    : {name}")
print(f"  common_bootbinary : boot.riscv -> {sys.argv[0]}")
PYEOF
echo "  workload dir      : $WORKLOAD_DIR"
echo "  symlink           : $WORKLOAD_DIR/boot.riscv -> $ELF"
