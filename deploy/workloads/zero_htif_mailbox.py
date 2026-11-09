#!/usr/bin/env python3
"""zero_htif_mailbox.py — zero the tohost/fromhost HTIF mailbox words in spike
checkpoint mem.elf images.

Why: these fullsys checkpoints run a bare SPEC binary through spike's HTIF
syscall proxy, so tohost/fromhost ARE the syscall mailbox. spike is edge-
triggered and leaves tohost pointing at the last-serviced syscall buffer
(harmless in spike). sparse_bin_to_elf.py stamps the tohost/fromhost SYMBOLS but
never clears the mailbox memory, so the stale pointer is baked into mem.elf. On
FireSim restore the FESVR is level-triggered: first poll follows the stale
pointer, reads syscall #0 from the (zeroed) buffer, and aborts with
'bad syscall #0'. A clean checkpoint has tohost=fromhost=0 (cf. intspeed-nowarmup).

This zeroes exactly the 8+8 bytes at the tohost/fromhost symbols, in place,
matching the clean state. Idempotent. Only touches 16 bytes; verifies before/after.

Usage: zero_htif_mailbox.py <mem.elf> [<mem.elf> ...]
"""
import sys, os, struct, subprocess


def sym_addr(elf, name):
    out = subprocess.check_output(['nm', elf], text=True, stderr=subprocess.DEVNULL)
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3 and p[2] == name:
            return int(p[0], 16)
    return None


def file_offset(elf, addr):
    """Map a load PhysAddr to a file offset via the containing PT_LOAD segment."""
    out = subprocess.check_output(['readelf', '-lW', elf], text=True, stderr=subprocess.DEVNULL)
    for line in out.splitlines():
        s = line.split()
        if len(s) >= 6 and s[0] == 'LOAD':
            try:
                off, vaddr, paddr, fsz = (int(s[1], 16), int(s[2], 16),
                                          int(s[3], 16), int(s[4], 16))
            except ValueError:
                continue
            if paddr <= addr < paddr + fsz:
                return off + (addr - paddr)
    return None


def patch(elf):
    to, fr = sym_addr(elf, 'tohost'), sym_addr(elf, 'fromhost')
    if to is None or fr is None:
        print(f"  SKIP: tohost/fromhost symbol missing ({to=}, {fr=})")
        return False
    ok = True
    size = os.path.getsize(elf)
    with open(elf, 'r+b') as f:
        for name, addr in (('fromhost', fr), ('tohost', to)):
            off = file_offset(elf, addr)
            if off is None or off + 8 > size:
                print(f"  ERROR {name} @ {addr:#x}: no containing segment / OOB")
                ok = False
                continue
            f.seek(off); before = struct.unpack('<Q', f.read(8))[0]
            if before != 0:
                f.seek(off); f.write(b'\x00' * 8)
            f.seek(off); after = struct.unpack('<Q', f.read(8))[0]
            flag = 'ok' if after == 0 else 'FAILED'
            print(f"  {name:9s} @ vaddr {addr:#013x} off {off:#010x}: "
                  f"{before:#018x} -> {after:#018x}  [{flag}]")
            ok = ok and after == 0
    return ok


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    allok = True
    for elf in sys.argv[1:]:
        print(elf)
        allok = patch(elf) and allok
    sys.exit(0 if allok else 1)
