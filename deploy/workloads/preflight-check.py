#!/usr/bin/env python3
"""
Pre-flight coherence check for a FireSim checkpoint-restore run.

WHY THIS EXISTS
---------------
Target DRAM has TWO independent writers, and the second silently wins:

  1. simulation_t::init_dram()          writes the +loadmem= image via XDMA
  2. htif_t::start() -> load_program()  writes boot.riscv over it

(2) runs after (1). testchip_dtm.h:75-78 overrides load_program() to set
is_loadmem, so that write takes the fast XDMA path: no log line, no measurable
wallclock, no symptom of any kind. If boot.riscv and +loadmem are different
files, +loadmem is silently discarded.

That mismatch discarded four consecutive rounds of firmware patches during
debugging, each of which "verified" fine on disk. Hence: verify the wiring
before spending a run, and verify target memory during the run with
+verify-mem= (testchip_dtm.cc).

Read-only. Modifies nothing. Exit 0 = all checks pass.

Usage:  python3 preflight-check.py [config_runtime_checkpoint.yaml]
"""
import os
import re
import struct
import subprocess
import sys

DEPLOY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRAM_BASE = 0x80000000

fails, warns = [], []


def ok(msg):
    print(f"  [ OK ] {msg}")


def fail(msg):
    print(f"  [FAIL] {msg}")
    fails.append(msg)


def warn(msg):
    print(f"  [warn] {msg}")
    warns.append(msg)


def head(t):
    print(f"\n=== {t} ===")


def read_cfg(path):
    """Pull the fields we care about without needing a yaml module."""
    txt = open(path).read()
    cfg = {}
    # plusarg_passthrough is the live one; ignore commented lines
    live = [l for l in txt.splitlines() if not l.strip().startswith("#")]
    live_txt = "\n".join(live)
    m = re.search(r"plusarg_passthrough:\s*\"([^\"]*)\"", live_txt)
    cfg["plusargs"] = m.group(1) if m else ""
    for key in ("default_hw_config", "workload_name"):
        m = re.search(rf"{key}:\s*(\S+)", live_txt)
        cfg[key] = m.group(1) if m else None
    for key in ("start", "end"):
        m = re.search(rf"^\s+{key}:\s*(\d+)", live_txt, re.M)
        cfg["trace_" + key] = int(m.group(1)) if m else None
    m = re.search(r"enable:\s*(\S+)", live_txt)
    cfg["trace_enable"] = m.group(1) if m else None
    return cfg


def plusarg(pa, name):
    m = re.search(rf"\+{name}=([^\s\"]+)", pa)
    return m.group(1) if m else None


def elf_segments(path):
    with open(path, "rb") as f:
        f.seek(24)
        e_entry, e_phoff = struct.unpack("<QQ", f.read(16))
        f.seek(54)
        e_phentsize, e_phnum = struct.unpack("<HH", f.read(4))
        segs = []
        for i in range(e_phnum):
            f.seek(e_phoff + i * e_phentsize)
            p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz = struct.unpack("<IIQQQQ", f.read(40))
            if p_type == 1:
                segs.append((p_paddr, p_filesz, p_offset))
    return e_entry, segs


def main():
    cfgp = sys.argv[1] if len(sys.argv) > 1 else os.path.join(DEPLOY, "config_runtime_checkpoint.yaml")
    print(f"pre-flight check: {cfgp}")
    cfg = read_cfg(cfgp)
    pa = cfg["plusargs"]

    loadmem = plusarg(pa, "loadmem")
    loadarch = plusarg(pa, "loadarch")
    maxcyc = plusarg(pa, "max-cycles")

    head("1. plusargs")
    print(f"  hw_config   : {cfg['default_hw_config']}")
    print(f"  workload    : {cfg['workload_name']}")
    print(f"  max-cycles  : {maxcyc}")
    print(f"  loadmem     : {loadmem}")
    print(f"  loadarch    : {loadarch}")
    if not loadmem:
        fail("no +loadmem= in plusarg_passthrough")
        return
    if not loadarch:
        fail("no +loadarch= in plusarg_passthrough")
        return
    for p in (loadmem, loadarch):
        if not os.path.exists(p):
            fail(f"path does not exist: {p}")
    if fails:
        return

    head("2. boot.riscv vs +loadmem  (THE check -- see module docstring)")
    wl = cfg["workload_name"].replace(".json", "") if cfg["workload_name"] else None
    bench = None
    wj = os.path.join(DEPLOY, "workloads", cfg["workload_name"] or "")
    if os.path.exists(wj):
        import json
        bench = json.load(open(wj)).get("benchmark_name")
    print(f"  workload json          : {wj}")
    print(f"  benchmark_name         : {bench}")
    boot = os.path.join(DEPLOY, "workloads", bench or "", "boot.riscv")
    if not os.path.exists(boot):
        fail(f"boot.riscv not found at {boot}")
        return
    boot_real = os.path.realpath(boot)
    lm_real = os.path.realpath(loadmem)
    print(f"  boot.riscv -> {boot_real}")
    print(f"  +loadmem   -> {lm_real}")
    if boot_real == lm_real:
        ok("boot.riscv and +loadmem are the SAME file -- no silent overwrite possible")
    else:
        fail("boot.riscv != +loadmem. FESVR's load_program() runs LAST and will "
             "OVERWRITE the +loadmem image. Point boot.riscv at the same file.")

    head("3. loadarch belongs to the same checkpoint")
    la_dir = os.path.dirname(os.path.abspath(loadarch))
    pristine = os.path.join(la_dir, "mem.elf")
    print(f"  loadarch dir           : {la_dir}")
    if os.path.exists(pristine):
        ok(f"sibling mem.elf present ({os.path.getsize(pristine)} bytes)")
        if os.path.getsize(pristine) != os.path.getsize(lm_real):
            fail("loaded image size != checkpoint mem.elf size -- different checkpoint!")
        else:
            rc = subprocess.run(["cmp", "-l", pristine, lm_real], capture_output=True, text=True)
            n = len(rc.stdout.splitlines())
            if n == 0:
                ok("loaded image is byte-identical to the checkpoint mem.elf")
            else:
                warn(f"loaded image differs from checkpoint mem.elf in {n} bytes "
                     f"(expected if you applied a deliberate patch)")
    else:
        warn(f"no mem.elf next to loadarch at {la_dir}")

    head("4. loadarch contents")
    lines = open(loadarch).read().splitlines()
    print(f"  lines: {len(lines)}")
    if len(lines) < 95:
        fail(f"loadarch has {len(lines)} lines, expected >= 95")
    else:
        ok("line count >= 95")
    nharts = lines[0].strip()
    pc, prv = lines[2].strip(), lines[3].strip()
    print(f"  nharts={nharts}  pc={pc}  prv={prv}")
    if nharts != "1":
        warn(f"nharts={nharts}; the target is single-hart")
    # satp: index 15 (0-based) given the positional layout
    try:
        satp = int(lines[15], 0)
        mode = satp >> 60
        print(f"  satp = {lines[15].strip()}  MODE={mode}")
        if mode == 10:
            ok("satp MODE=10 (Sv57) -- requires a pgLevels=5 build")
        else:
            warn(f"satp MODE={mode}, not Sv57")
    except Exception as e:
        warn(f"could not parse satp: {e}")
    ntrap = sum(1 for l in lines if "trap_illegal_instruction" in l)
    if ntrap:
        # These land on the 5 vector CSRs, which are guarded by has_vector.
        has_vlen = any("VLEN" in l for l in lines)
        if has_vlen:
            fail(f"{ntrap} garbage lines AND a VLEN line -- vector restore would use garbage")
        else:
            ok(f"{ntrap} spike-error lines occupy the vector CSR slots; no VLEN line, so "
               f"has_vector=false and they are never written to the target (inert)")

    head("5. loaded ELF")
    entry, segs = elf_segments(lm_real)
    print(f"  entry = {entry:#x}, {len(segs)} PT_LOAD segments")
    dram_top = DRAM_BASE + (32 << 30)
    for p_paddr, p_filesz, p_off in segs:
        end = p_paddr + p_filesz
        inrange = DRAM_BASE <= p_paddr and end <= dram_top
        print(f"    paddr={p_paddr:#012x} filesz={p_filesz:#x} end={end:#012x} "
              f"{'' if inrange else '<-- OUTSIDE DRAM'}")
        if not inrange:
            fail(f"segment at {p_paddr:#x} extends past the 32 GiB DRAM window")
    if all(DRAM_BASE <= a and a + s <= dram_top for a, s, _ in segs):
        ok("all PT_LOAD segments fit inside DRAM [0x80000000, +32GiB)")
    nm = "/home/jht9sy/work/chipyard/.conda-env/riscv-tools/bin/riscv64-unknown-elf-nm"
    if os.path.exists(nm):
        out = subprocess.run([nm, lm_real], capture_output=True, text=True).stdout
        syms = {s: (s in out) for s in ("tohost", "fromhost")}
        if all(syms.values()):
            ok("tohost and fromhost symbols present (FESVR can resolve HTIF)")
        else:
            fail(f"missing HTIF symbols: {syms}")

    head("6. firmware bytes that will actually execute")
    # p_offset of segment 0 maps vaddr 0x80000000
    seg0_off = segs[0][2]
    pts = [("uart8250_putc", 0x8000CCE8, 4), ("sbi_printf", 0x80006E26, 2),
           ("mtvec", 0x80000418, 4)]
    with open(lm_real, "rb") as f:
        for name, va, n in pts:
            f.seek(seg0_off + va - DRAM_BASE)
            b = f.read(n)
            print(f"  {name:<14} @{va:#010x} = {b.hex()}")
    print("  (pass these to +verify-mem= to confirm they survive into target DRAM)")

    head("7. sparse image vs DRAM zeroing  (correctness, not hygiene)")
    covered = sum(s for _, s, _ in segs)
    window = dram_top - DRAM_BASE
    pct = 100.0 * covered / window
    print(f"  image covers {covered/2**20:.0f} MiB of a {window/2**30:.0f} GiB window ({pct:.2f}%)")
    prev, gaps = DRAM_BASE, []
    for a, s, _ in sorted(segs):
        if a > prev:
            gaps.append((prev, a - prev))
        prev = a + s
    if dram_top > prev:
        gaps.append((prev, dram_top - prev))
    for a, sz in gaps:
        print(f"    gap {a:#012x} +{sz/2**20:.0f} MiB")
    txt = open(cfgp).read()
    live = "\n".join(l for l in txt.splitlines() if not l.strip().startswith("#"))
    m = re.search(r"zero_out_dram:\s*(\S+)", live)
    zod = m.group(1) if m else None
    print(f"  zero_out_dram = {zod}")
    if gaps and zod not in ("yes", "true", "True"):
        fail("SPARSE image with zero_out_dram disabled. Spike serves untouched pages as "
             "ZERO; FPGA DRAM is persistent and holds prior checkpoints' data. The gaps "
             "above will be read as another benchmark's memory -> corrupt restore.")
    elif gaps:
        ok("gaps will be zeroed before load (matches spike's zero-fill semantics)")

    head("8. tracing / run limits")
    print(f"  trace enable={cfg['trace_enable']} start={cfg['trace_start']} end={cfg['trace_end']}")
    print(f"  max-cycles  ={maxcyc}")
    if cfg["trace_end"] and maxcyc and int(cfg["trace_end"]) > int(maxcyc):
        warn("trace end > max-cycles; the window is truncated by the run limit")
    if maxcyc and int(maxcyc) < 100_000_000:
        warn(f"max-cycles={maxcyc} is a DEBUG value; raise to ~2e9 for a real IPC run")

    print("\n" + "=" * 66)
    if fails:
        print(f"PRE-FLIGHT FAILED: {len(fails)} error(s), {len(warns)} warning(s)")
        for f_ in fails:
            print(f"  - {f_}")
        return 1
    print(f"PRE-FLIGHT PASSED ({len(warns)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
