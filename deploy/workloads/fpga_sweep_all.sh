#!/usr/bin/env bash
# fpga_sweep_all.sh -- sweep MANY benchmarks across BOTH FPGAs, infrasetup-ONCE per card.
#
#   Phase 1 (serialized): infrasetup BOTH cards while NEITHER is simulating -- the only
#                         rmmod/insmod xdma, done back-to-back so both succeed.
#   Phase 2 (parallel):   each card runs its benchmark list runworkload-ONLY (boot-symlink swap
#                         + config update). No further xdma touch -> the two cards run fully
#                         concurrently without fighting over the shared xdma module.
#
# Output: $RUN/$CONFIG/<benchmark>/<simpoint>/{run.log, AUTOCOUNTERFILE0.csv, uartlog, stats.txt}
#         + per-benchmark SimPoint-weighted IPC at the end.
# PREREQ: firesim_setup; BOTH FPGAs idle.   USAGE: bash deploy/workloads/fpga_sweep_all.sh
set -uo pipefail

DEPLOY_DIR=/home/jht9sy/work/chipyard/sims/firesim/deploy
FSIM_ROOT=/home/jht9sy/work/chipyard/sims/firesim
WL_DIR=$DEPLOY_DIR/workloads
BASE=/data/akrish/checkpoints/spec17-intspeed-fullsys-spike
WARMUP=50000000; MEASURE=100000000; MAXCYC=2000000000
CONFIG=${FPGA_CONFIG:-default}
SPS=(sp_0 sp_1 sp_2 sp_3 sp_4)

# ---- benchmark split across the two cards (edit here to change the matrix) ----
FPGAS=(1 0)
declare -A BENCHES=(
  [1]="600.perlbench_s 602.gcc_s 605.mcf_s 620.omnetpp_s 623.xalancbmk_s 625.x264_s"
  [0]="631.deepsjeng_s 641.leela_s 648.exchange2_s 657.xz_s-workload0 657.xz_s-workload1"
)
declare -A BDF=(   [1]=3b:00.0                        [0]=5e:00.0 )
declare -A CFGF=(  [1]=config_runtime_checkpoint.yaml [0]=config_runtime_checkpoint_0.yaml )
declare -A JSONF=( [1]=checkpoint-run.json            [0]=checkpoint-run_0.json )
declare -A SIMDIR=([1]=/data/akrish/firesim/simulation-1 [0]=/data/akrish/firesim/simulation )

TS=$(date +%Y%m%d-%H%M%S); RUN=/data/akrish/firesim/fpga-sweep-all-$TS; mkdir -p "$RUN/state"
cd "$FSIM_ROOT" || { echo "cannot cd"; exit 1; }
command -v firesim >/dev/null || { echo "ERROR: run firesim_setup first"; exit 1; }
timeout 10 ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost true 2>/dev/null || { echo "ERROR: ssh localhost failed -- firesim_setup"; exit 1; }

declare -A WCFG WJSON WJREL
WJDIR=.sweepall-$TS; mkdir -p "$WL_DIR/$WJDIR"
for fid in "${FPGAS[@]}"; do
  WCFG[$fid]=$RUN/cfg.$fid.yaml; WJREL[$fid]=$WJDIR/$fid.json; WJSON[$fid]=$WL_DIR/${WJREL[$fid]}
  cp -p "$DEPLOY_DIR/${CFGF[$fid]}" "${WCFG[$fid]}"; cp -p "$WL_DIR/${JSONF[$fid]}" "${WJSON[$fid]}"
  sed -i "s|^\([[:space:]]*workload_name:\).*|\1 ${WJREL[$fid]}|" "${WCFG[$fid]}"
done
trap 'rm -rf "$WL_DIR/$WJDIR" 2>/dev/null' EXIT
trap 'echo; echo "[INTERRUPTED]"; pkill -SIGKILL -f FireSim-xilinx_alveo_u250 2>/dev/null; screen -wipe >/dev/null 2>&1; exit 130' INT TERM

wait_xdma() { local sd=/sys/bus/pci/devices/0000:$1/xdma h2c n i; for i in $(seq 1 120); do
  h2c=$(ls "$sd" 2>/dev/null | grep -oE 'xdma[0-9]+_h2c_0' | head -1)
  [ -n "$h2c" ] && { n=${h2c#xdma}; n=${n%%_*}; [ -e "/dev/xdma${n}_user" ] && { sleep 1; return 0; }; }
  sleep 1; done; return 1; }

extract_stats() { python3 - "$1" "$WARMUP" "$MEASURE" <<'PY'
import csv,sys
f,warm,meas=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
try: rows=list(csv.reader(open(f)))
except Exception: print("N/A"); sys.exit()
hdr=next((r for r in rows if r and r[0]=='label'),None)
if not hdr: print("N/A"); sys.exit()
def col(n):
    try: return next(i for i,h in enumerate(hdr) if h.endswith(n))
    except StopIteration: return None
CS=[col('CommitSlot%d'%k) for k in range(4)]; LC=col('local_cycle')
if any(c is None for c in CS) or LC is None: print("N/A"); sys.exit()
data=[r for r in rows if r and r[0].lstrip('-').isdigit()]
def C(r): return sum(int(r[i]) for i in CS)
base=next((C(r) for r in data if C(r)>0),None)
if base is None: print("N/A"); sys.exit()
rw=next((r for r in data if C(r)-base>=warm),None); rm=next((r for r in data if C(r)-base>=warm+meas),None)
if not (rw and rm): print("N/A"); sys.exit()
ins=C(rm)-C(rw); cyc=int(rm[LC])-int(rw[LC])
if ins<=0 or cyc<=0: print("N/A"); sys.exit()
def d(n):
    i=col(n); return (int(rm[i])-int(rw[i])) if i is not None else 0
mp=lambda n:d(n)*1000.0/ins; pc=lambda n:d(n)*100.0/cyc
print(f"{ins/cyc:.4f} {ins} {cyc} {mp('DCacheMiss'):.2f} {mp('DTLBMiss'):.2f} {mp('ICacheMiss'):.3f} {mp('ITLBMiss'):.3f} {mp('BrMispredict'):.2f} {pc('FetchStall'):.2f} {pc('ROBFullStall'):.2f} {pc('LDQFullStall'):.2f} {pc('STQFullStall'):.2f}")
PY
}
stage() { local name=$1 sp=$2 cfg=$3 wjson=$4 slot=$5 log=$6
  bash "$WL_DIR/set-checkpoint-run.sh" "$name" "$sp/mem.elf" "$sp/loadarch" "$cfg" "$wjson" >>"$log" 2>&1
  sed -i "s|+max-cycles=[0-9]*|+max-cycles=$MAXCYC|" "$cfg"
  ln -sf "$(realpath "$sp/mem.elf")" "$slot/${name}0-boot.riscv"; }
# The slot boot.riscv symlink IS REQUIRED and must stay: fpga_sweep_all runs infrasetup ONCE,
# so the manager only ever creates the FIRST checkpoint's slot boot.riscv; the sim opens
# slot/<name>0-boot.riscv per checkpoint for FESVR tohost/fromhost symbols, so every later
# checkpoint needs this line. Deleting it (an earlier over-correction) broke the sweep --
# sp_1+ died at startup: "could not open <name>0-boot.riscv". Mode-1 corruption is prevented
# by the purge-before-Phase-1 below (clears stale ACCUMULATED symlinks that a later infrasetup
# cp would write THROUGH into the wrong source); with the purge + writable sources, the single
# current-checkpoint symlink is an identity write, not corruption. (Symbols are identical in
# source vs uart-patched, so the source symlink is correct even when +loadmem uses the patch.)

# ---- Phase 1: infrasetup each card ONCE (serialized; neither is running yet) ----
setup_fpga() {
  local fid=$1 cfg=${WCFG[$fid]} wjson=${WJSON[$fid]} slot=${SIMDIR[$fid]}/sim_slot_0
  local b0; b0=$(echo "${BENCHES[$fid]}" | awk '{print $1}'); local sp0=$BASE/checkpoints/$b0/sp_0
  echo "  [setup FPGA $fid] infrasetup (flash + load xdma) via $b0/sp_0 ..."
  stage "$b0-sp_0" "$sp0" "$cfg" "$wjson" "$slot" "$RUN/setup.$fid.log"
  firesim -c "$cfg" infrasetup >>"$RUN/setup.$fid.log" 2>&1 || { echo "  [setup FPGA $fid] FAILED"; return 1; }
  wait_xdma "${BDF[$fid]}" || { echo "  [setup FPGA $fid] xdma not ready"; return 1; }
  echo "  [setup FPGA $fid] done."
}

# ---- Phase 2: per-card runworkload-only sweep over its benchmarks x simpoints ----
run_sweep() {
  local fid=$1 cfg=${WCFG[$fid]} wjson=${WJSON[$fid]} slot=${SIMDIR[$fid]}/sim_slot_0
  local b spn name sp bclean spdir st
  for b in ${BENCHES[$fid]}; do
    bclean=$(echo "$b" | sed 's/^[0-9]*\.//; s/_s$//; s/_s-/-/')
    for spn in "${SPS[@]}"; do
      name=$b-$spn; sp=$BASE/checkpoints/$b/$spn; spdir=$RUN/$CONFIG/$bclean/$spn; mkdir -p "$spdir"
      local flog=$spdir/run.log; : > "$flog"
      setstate() { echo "$b|$spn|$1" > "$RUN/state/fpga.$fid"; }
      [[ -f "$sp/mem.elf" && -f "$sp/loadarch" ]] || { echo "MISSING" >"$spdir/stats.txt"; continue; }
      setstate "setup"
      stage "$name" "$sp" "$cfg" "$wjson" "$slot" "$flog"
      rm -f "$slot/AUTOCOUNTERFILE0.csv" "$slot/uartlog" 2>/dev/null
      setstate "runworkload"
      # Avoid the cross-card topology-render race: both cards' runworkloads render the SAME file
      # generated-topology-diagrams/firesim_topology<topo>.gv early in startup; concurrent renders
      # corrupt it -> graphviz "syntax error" -> RUN_FAIL. Hold a cross-card lock only for the
      # ~render window (RENDER_GUARD s), then release so the long sims still overlap.
      exec 200>>"$RUN/.runworkload.lock"; flock 200
      firesim -c "$cfg" runworkload >>"$flog" 2>&1 &
      rwpid=$!; sleep "${RENDER_GUARD:-40}"; flock -u 200; exec 200>&-
      if ! wait "$rwpid"; then echo "RUN_FAIL" >"$spdir/stats.txt"; continue; fi
      local rdir uart ac
      rdir=$(ls -dt "$DEPLOY_DIR/results-workload/"????-??-??--??-??-??-"$name"/ 2>/dev/null | head -1)
      uart=$(find "$rdir" -name uartlog 2>/dev/null | head -1); [ -n "$uart" ] && cp -p "$uart" "$spdir/" 2>/dev/null
      ac="$rdir/${name}0/AUTOCOUNTERFILE0.csv"; cp -p "$ac" "$spdir/" 2>/dev/null
      # A run is VALID if its AutoCounter reached the measurement window -- do NOT require the
      # "Simulation complete" line. exchange2 sp_2 ran the full 2B cycles (complete AutoCounter,
      # IPC 1.42) but the driver was killed at teardown before printing it; the old check
      # mis-flagged that DRIVER_CRASH. Only a hard crash or an absent AutoCounter is a real failure;
      # extract_stats below returns N/A (=> WINDOW_SHORT) if the 50M+100M window was never reached.
      if grep -qE 'Aborted|core dumped' "$uart" 2>/dev/null || [[ ! -s "$ac" ]]; then
        echo "DRIVER_CRASH" >"$spdir/stats.txt"; continue; fi
      st=$(extract_stats "$ac")
      if [[ "$st" == "N/A" || -z "$st" ]]; then echo "WINDOW_SHORT" >"$spdir/stats.txt"; continue; fi
      { echo "# ipc instr cycles dc_mpki dtlb_mpki ic_mpki itlb_mpki br_mpki fetch% rob% ldq% stq%"; echo "$st"; } >"$spdir/stats.txt"
    done
  done
  setstate() { echo "$b|(done)|idle" > "$RUN/state/fpga.$fid"; }; setstate
}

echo "fpga_sweep_all -> $RUN   (config=$CONFIG)"
for fid in "${FPGAS[@]}"; do echo "  FPGA $fid (${BDF[$fid]}): ${BENCHES[$fid]}"; done
echo
# ANTI-CORRUPTION (root-caused 2026-07-29): the FireSim manager runs `cp -r rsyncdir/* slot/` during
# infrasetup. That FOLLOWS any slot/<name>0-boot.riscv symlink stage() points at a SOURCE mem.elf and
# OVERWRITES the source checkpoint with rsyncdir's copy. rsyncdir + the slot symlinks ACCUMULATE across
# runs, so those copies go STALE (old/corrupt) and one cp silently reverts many source checkpoints to
# a corrupt image (this destroyed perlbench sp1-4 / gcc sp0-1 on 2026-07-29). Purge both every sweep so
# cp can only ever write the current checkpoint's own freshly-rsync'd content (identity). Do NOT remove.
echo "== purge stale slot boot.riscv symlinks + rsyncdir (anti-corruption) =="
for fid in "${FPGAS[@]}"; do
  slot=${SIMDIR[$fid]}/sim_slot_0
  rm -f "$slot"/*-boot.riscv 2>/dev/null || true
  rm -rf "$slot"/rsyncdir 2>/dev/null || true
done
echo "== Phase 1: infrasetup both cards (serialized) =="
for fid in "${FPGAS[@]}"; do setup_fpga "$fid" || { echo "setup failed on FPGA $fid"; exit 1; }; done
echo
echo "== Phase 2: parallel runworkload-only sweeps =="
declare -A WPID
for fid in "${FPGAS[@]}"; do run_sweep "$fid" & WPID[$fid]=$!; done
for fid in "${FPGAS[@]}"; do wait "${WPID[$fid]}"; done

echo; echo "== per-benchmark SimPoint-weighted IPC =="
python3 - "$BASE" "$RUN/$CONFIG" <<'PY'
import os,glob,sys
base,root=sys.argv[1],sys.argv[2]
def weights(b):
    d={}; wf=f"{base}/simpoints/{b}.weights"
    if os.path.exists(wf):
        for l in open(wf):
            p=l.split()
            if len(p)>=2:
                try: d[int(p[1])]=float(p[0])
                except ValueError: pass
    return d
# map cleaned dir name back to the spec benchmark name for weights
import re
def specname(bclean):
    for wf in glob.glob(f"{base}/simpoints/*.weights"):
        b=os.path.basename(wf)[:-8]
        if re.sub(r'^[0-9]*\.','',re.sub(r'_s$','',re.sub(r'_s-','-',b)))==bclean: return b
    return None
for d in sorted(glob.glob(f"{root}/*")):
    if not os.path.isdir(d): continue
    bclean=os.path.basename(d); b=specname(bclean); wd=weights(b) if b else {}
    tot=wi=0.0; got=[]
    for sd in sorted(glob.glob(f"{d}/sp_*"), key=lambda p:int(p.rsplit('sp_',1)[1])):
        n=int(sd.rsplit('sp_',1)[1]); sf=f"{sd}/stats.txt"
        if not os.path.exists(sf): continue
        L=[l for l in open(sf) if l.strip() and not l.startswith('#')]
        if not L or len(L[0].split())<2: print(f"  {bclean} sp_{n}: {open(sf).read().strip()}"); continue
        p=L[0].split(); ipc=float(p[0])
        # SPIN detector (same as dashboard mark()): zero D$/I$/branch misses over the window.
        # Exclude spinners -- their 0.15/0.31 IPC would corrupt the weighted average.
        if len(p)>=8 and float(p[3])==0 and float(p[5])==0 and float(p[7])==0:
            print(f"  {bclean} sp_{n}: SPIN ipc={ipc:.3f} (excluded from weighted IPC)"); continue
        w=wd.get(n,0.0); tot+=w; wi+=w*ipc; got.append((n,w,ipc))
    if tot>0:
        print(f"  {bclean:14s} weighted IPC = {wi/tot:.4f}  (cov {tot:.3f})  [" + " ".join(f"sp{n}={ipc:.3f}" for n,_,ipc in got) + "]")
PY
echo "outputs in $RUN"
