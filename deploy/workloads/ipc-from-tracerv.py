#!/usr/bin/env python3
"""
ipc-from-tracerv.py — Extract IPC from a FireSim TracerV human-readable trace.

Usage:
    python3 ipc-from-tracerv.py <tracerv.out-C0> [--restore-cycle N] [--warmup M] [--measure K]

Defaults:
    --restore-cycle 702000000   cycle after which hart resumes (post-TSI + post-loadarch)
    --warmup        30000000    instructions to skip for cache/predictor warmup
    --measure       50000000    instructions to measure for IPC

Output:
    IPC = <measure> / (cycle_end - cycle_start)
"""

import argparse
import os
import sys


def find_byte_offset_for_cycle(path, target_cycle, filesize):
    """Binary search for the byte offset of the first line with cycle >= target_cycle."""
    lo, hi = 0, filesize
    with open(path, 'rb') as f:
        while hi - lo > 4096:
            mid = (lo + hi) // 2
            f.seek(mid)
            f.readline()  # skip partial line
            line = f.readline().decode('ascii', 'ignore').strip()
            if line.startswith('Cycle:'):
                if int(line.split()[1]) < target_cycle:
                    lo = mid
                else:
                    hi = mid
            else:
                hi = mid
    return lo


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('tracefile')
    parser.add_argument('--restore-cycle', type=int, default=702_000_000,
                        help='Simulation cycle when harts resume after loadarch (default: 702000000)')
    parser.add_argument('--warmup', type=int, default=30_000_000,
                        help='Instructions to skip as warmup (default: 30M)')
    parser.add_argument('--measure', type=int, default=50_000_000,
                        help='Instructions to measure for IPC (default: 50M)')
    args = parser.parse_args()

    path = args.tracefile
    if not os.path.exists(path):
        print(f'ERROR: file not found: {path}', file=sys.stderr)
        sys.exit(1)

    filesize = os.path.getsize(path)
    total_window = args.warmup + args.measure

    print(f'Trace file : {path}')
    print(f'File size  : {filesize / 1e9:.2f} GB')
    print(f'Restore >=  cycle {args.restore_cycle:,}')
    print(f'Warmup     : {args.warmup:,} instructions (skipped)')
    print(f'Measure    : {args.measure:,} instructions')
    print()

    # Find byte offset near the restore cycle
    offset = find_byte_offset_for_cycle(path, args.restore_cycle, filesize)

    warmup_end_cycle = None
    measure_end_cycle = None
    count = 0

    with open(path, 'rb') as f:
        f.seek(offset)
        f.readline()  # skip partial line at seek point
        for raw in f:
            line = raw.decode('ascii', 'ignore').strip()
            if not line.startswith('Cycle:'):
                continue
            parts = line.split()
            cycle = int(parts[1])
            count += 1

            if count == args.warmup:
                warmup_end_cycle = cycle
                print(f'Warmup complete at instruction {count:,}, cycle {cycle:,}')

            if count == total_window:
                measure_end_cycle = cycle
                print(f'Measurement complete at instruction {count:,}, cycle {cycle:,}')
                break

    if warmup_end_cycle is None:
        print(f'\nERROR: only {count:,} instructions found after restore cycle {args.restore_cycle:,}.')
        print(f'Need {args.warmup:,} for warmup alone. Increase +max-cycles and re-run.')
        sys.exit(1)

    if measure_end_cycle is None:
        print(f'\nERROR: only {count:,} post-warmup instructions found (need {total_window:,}).')
        print(f'Increase +max-cycles and re-run.')
        sys.exit(1)

    cycles_for_measure = measure_end_cycle - warmup_end_cycle
    ipc = args.measure / cycles_for_measure

    print()
    print(f'Measurement window : {args.measure:,} instructions')
    print(f'Cycles in window   : {cycles_for_measure:,}')
    print(f'IPC                : {ipc:.4f}')


if __name__ == '__main__':
    main()
