#!/usr/bin/env python3
"""check_checkpoint_integrity.py — verify a spike checkpoint's mem.elf is not corrupt
by walking the restored Sv57 page table for the checkpoint's own (satp, pc).

A run "spins" (traps on resume -> OpenSBI -> _start_warm loop) when the mem.elf
page-table pages hold garbage (e.g. file-cache text where PTEs belong). Spike
restored these fine when generated; the on-disk images can rot from a bad copy.
This is a fast pre-flight gate: it reads only a handful of 8-byte PTEs per checkpoint.

Usage:
  check_checkpoint_integrity.py <BASE>/checkpoints           # scan every <bench>/<sp>
  check_checkpoint_integrity.py <ckpt_dir>                   # one dir with mem.elf+loadarch
Exit code 0 iff every checkpoint walks to a valid leaf instruction.

loadarch field order (spike dump): line0=nharts, line1=':' sep, line2=pc, ...,
satp is the 14th scalar after pc -> file index 15 (0-based). Verified against
testchip_dtm.cc loadarch parser.
"""
import sys, os, struct, subprocess

def load_segments(elf):
    out = subprocess.check_output(['readelf', '-lW', elf], text=True,
                                  stderr=subprocess.DEVNULL).splitlines()
    segs = []
    for l in out:
        s = l.split()
        if len(s) >= 6 and s[0] == 'LOAD':
            try:
                off, _va, pa, fsz = int(s[1],16), int(s[2],16), int(s[3],16), int(s[4],16)
            except ValueError:
                continue
            segs.append((off, pa, fsz))
    return segs

def make_rd(elf):
    segs = load_segments(elf); f = open(elf, 'rb')
    def rd8(pa):
        for off, base, fsz in segs:
            if base <= pa < base + fsz:
                f.seek(off + (pa - base)); return struct.unpack('<Q', f.read(8))[0]
        return None                      # not in image -> reads 0 on FPGA
    return rd8

def satp_pc(loadarch):
    L = [x.strip() for x in open(loadarch)]
    prv = L[3]                             # 'M' / 'S' / 'U'
    return int(L[15], 16), int(L[2], 16), prv  # satp, pc, prv

def walk(elf, satp, va):
    rd8 = make_rd(elf); a = (satp & ((1 << 44) - 1)) * 4096
    mode = (satp >> 60) & 0xF
    if mode != 0xA:
        return False, f"satp mode {mode:#x} != Sv57"
    for i in (4, 3, 2, 1, 0):
        pte = rd8(a + ((va >> (12 + 9*i)) & 0x1FF) * 8)
        if pte is None:
            return False, f"L{i} PTE page not in image"
        if not (pte & 1):
            b = (pte & 0xFFFFFFFFFFFFFFFF).to_bytes(8, 'little')
            ascii_ = b.decode('latin1') if all(9 <= x < 127 for x in b) else None
            return False, f"L{i} invalid PTE" + (f" (ASCII {ascii_!r})" if ascii_ else f" ({pte:#018x})")
        if pte & 0xE:                     # leaf
            nppn = (pte >> 10) & ((1 << 44) - 1)
            pa = (nppn << 12) | (va & ((1 << (12 + 9*i)) - 1))
            insn = rd8(pa & ~7)
            if insn is None:
                return False, "leaf OK but code page missing"
            iw = (insn >> ((pa & 7) * 8)) & 0xFFFFFFFF
            return True, f"leaf PA={pa:#x} insn={iw:#010x}"
        a = ((pte >> 10) & ((1 << 44) - 1)) * 4096
    return False, "no leaf"

def check_dir(d):
    elf, la = os.path.join(d, 'mem.elf'), os.path.join(d, 'loadarch')
    if not (os.path.exists(elf) and os.path.exists(la)):
        return None
    try:
        satp, pc, prv = satp_pc(la)
        mode = (satp >> 60) & 0xF
        # In M-mode (or with Bare paging) instruction fetch is PHYSICAL — no page walk.
        # Walking satp's tree for a physical firmware PC gives a bogus "corrupt" verdict.
        if prv == 'M' or mode == 0:
            rd8 = make_rd(elf)
            w = rd8(pc & ~7)
            if w is None:
                return (False, f"prv={prv} phys pc={pc:#x} not in image")
            iw = (w >> ((pc & 7) * 8)) & 0xFFFFFFFF
            return (iw != 0, f"prv={prv} phys pc={pc:#x} insn={iw:#010x}")
        return walk(elf, satp, pc)
    except Exception as e:
        return (False, f"ERROR {e}")

def main():
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(2)
    root = sys.argv[1]; dirs = []
    if os.path.exists(os.path.join(root, 'mem.elf')):
        dirs = [root]
    else:
        for b in sorted(os.listdir(root)):
            bd = os.path.join(root, b)
            if os.path.isdir(bd):
                for sp in sorted(os.listdir(bd)):
                    if os.path.exists(os.path.join(bd, sp, 'mem.elf')):
                        dirs.append(os.path.join(bd, sp))
    bad = 0
    for d in dirs:
        r = check_dir(d)
        if r is None: continue
        ok, msg = r
        rel = os.path.relpath(d, root)
        print(f"  {'OK  ' if ok else 'BAD '} {rel:32s} {msg}")
        bad += (not ok)
    print(f"\n{len(dirs)-bad}/{len(dirs)} clean, {bad} CORRUPT")
    sys.exit(1 if bad else 0)

if __name__ == '__main__':
    main()
