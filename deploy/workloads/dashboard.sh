#!/usr/bin/env bash
# dashboard.sh -- htop-style live view of the 2-FPGA checkpoint sweep. Read-only; never touches the
# sweep. Uses the alternate screen buffer + in-place cursor redraw: it takes over the pane while
# running and RESTORES your terminal (no scrollback pollution) on quit. Ctrl-C / q to exit.
#
#   bash deploy/workloads/dashboard.sh [RUN_DIR] [REFRESH_SEC]
set -uo pipefail
RUN=${1:-$(ls -dt /data/akrish/firesim/fpga-sweep-all-* 2>/dev/null | head -1)}
REFRESH=${2:-3}
BASE=/data/akrish/checkpoints/spec17-intspeed-fullsys-spike
MAXCYC=2000000000; TOTAL=55
declare -A SIMDIR=( [1]=/data/akrish/firesim/simulation-1 [0]=/data/akrish/firesim/simulation )
declare -A BUS=(    [1]=3b                                 [0]=5e )
FPGAS=(1 0)
[ -d "$RUN" ] || { echo "no sweep run dir found. pass one as arg1."; exit 1; }
CONFIG=$(ls "$RUN" 2>/dev/null | grep -vE 'cfg\.|state|\.log|\.yaml' | head -1); CONFIG=${CONFIG:-default}
START=$(stat -c %Y "$RUN" 2>/dev/null || echo 0)
SPS=(sp_0 sp_1 sp_2 sp_3 sp_4)
SPIN='|/-\'

# --- per-slot live counters: "cyc_pct cum_ins cum_ipc" (or "NA") ---
live_ac(){ python3 - "$1" "$MAXCYC" <<'PY' 2>/dev/null || echo "NA 0 --"
import csv,sys
try: rows=list(csv.reader(open(sys.argv[1])))
except Exception: print("NA 0 --"); sys.exit()
mx=int(sys.argv[2]); hdr=next((r for r in rows if r and r[0]=='label'),None)
if not hdr: print("NA 0 --"); sys.exit()
col=lambda n: next((i for i,h in enumerate(hdr) if h.endswith(n)),None)
CS=[col('CommitSlot%d'%k) for k in range(4)]; LC=col('local_cycle')
if any(c is None for c in CS) or LC is None: print("NA 0 --"); sys.exit()
data=[r for r in rows if r and r[0].lstrip('-').isdigit()]
if not data: print("0 0 --"); sys.exit()
C=lambda r: sum(int(r[i]) for i in CS)
b=next((r for r in data if C(r)>0),None)
if b is None: print("0 0 --"); sys.exit()
ins=C(data[-1])-C(b); cyc=int(data[-1][LC])-int(b[LC])
ipc=ins/cyc if cyc>0 else 0
print(f"{ins} {ins} {ipc:.3f}")   # note: cyc% is unreliable (accumulator); report ins instead
PY
}
# classify a stats.txt line 2 -> marker  (ok / diverged / fail / pending)
# stats fields: 1=ipc 2=instr 3=cyc 4=dc_mpki 5=dtlb 6=ic_mpki 7=itlb 8=br_mpki ...
# SPIN = a full 100M-instr window with ZERO D$/I$/branch-mispredict events (rate-independent):
# a cache-resident degenerate loop has no misses; real code always has some over 100M instrs.
# winipc <autocounter.csv> -> measure-window IPC (50M warmup + 100M measure), else empty.
# Mirrors fpga_sweep_all extract_stats; used to RECOVER a run flagged as a crash whose AutoCounter
# actually completed the window (driver died at teardown, e.g. exchange2 sp_2).
winipc(){ [ -s "$1" ] || return; python3 - "$1" <<'PY' 2>/dev/null
import csv,sys
try: rows=list(csv.reader(open(sys.argv[1])))
except Exception: sys.exit()
hdr=next((r for r in rows if r and r[0]=='label'),None)
if not hdr: sys.exit()
col=lambda n: next((i for i,h in enumerate(hdr) if h.endswith(n)),None)
CS=[col('CommitSlot%d'%k) for k in range(4)]; LC=col('local_cycle')
if any(c is None for c in CS) or LC is None: sys.exit()
data=[r for r in rows if r and r[0].lstrip('-').isdigit()]
C=lambda r: sum(int(r[i]) for i in CS)
base=next((C(r) for r in data if C(r)>0),None)
if base is None: sys.exit()
rw=next((r for r in data if C(r)-base>=50000000),None); rm=next((r for r in data if C(r)-base>=150000000),None)
if not(rw and rm): sys.exit()
ins=C(rm)-C(rw); cyc=int(rm[LC])-int(rw[LC])
if ins>0 and cyc>0: print(f"{ins/cyc:.4f}")
PY
}
mark(){ local d h; d=$(sed -n 2p "$1" 2>/dev/null); h=$(head -1 "$1" 2>/dev/null)
  if [[ "$d" =~ ^[0-9] ]]; then
    set -- $d
    if awk -v dc="$4" -v ic="$6" -v br="$8" 'BEGIN{exit !(dc==0 && ic==0 && br==0)}'; then echo diverged
    else echo "ok $1"; fi
  elif [[ "$h" =~ RUN_FAIL|DRIVER_CRASH|HANG|MISSING|WINDOW_SHORT ]]; then
    # False crash? If the copied AutoCounter reached the measurement window, recover it as ok.
    local rec; rec=$(winipc "$(dirname "$1")/AUTOCOUNTERFILE0.csv")
    [[ -n "$rec" ]] && echo "ok $rec" || echo "fail $h"
  else echo pending; fi; }

cleanup(){ printf '\033[?25h\033[?1049l'; exit 0; }
trap cleanup INT TERM EXIT
printf '\033[?1049h\033[?25l'          # alternate screen + hide cursor
tick=0
while true; do
  tick=$((tick+1)); COLS=$(tput cols 2>/dev/null||echo 100); sp=${SPIN:$((tick%4)):1}
  done=$(find "$RUN/$CONFIG" -name stats.txt 2>/dev/null | wc -l)
  el=$(( $(date +%s) - START )); eh=$((el/3600)); em=$(((el%3600)/60))
  eta="--"; [ "$done" -gt 0 ] && { e=$(((TOTAL-done)*el/done)); eta="$((e/3600))h$(((e%3600)/60))m"; }
  L=()
  L+=("$(printf '\033[1;36mFPGA SWEEP\033[0m  %s  \033[2mcfg=%s\033[0m' "$(basename "$RUN")" "$CONFIG")")
  L+=("$(printf '\033[32m●LIVE\033[0m %s \033[36m[%s]\033[0m t%d/%ss   done \033[1m%d/%d\033[0m   elapsed %dh%02dm   eta %s' "$(date +%T)" "$sp" "$tick" "$REFRESH" "$done" "$TOTAL" "$eh" "$em" "$eta")")
  L+=("$(printf '\033[2m%*s\033[0m' 70 '' | tr ' ' '-')")
  for fid in "${FPGAS[@]}"; do
    IFS='|' read -r fb fsp fph <<<"$(cat "$RUN/state/fpga.$fid" 2>/dev/null)"
    cb=$(echo "${fb:-?}" | sed 's/^[0-9]*\.//;s/_s$//;s/_s-/-/')
    acf="${SIMDIR[$fid]}/sim_slot_0/AUTOCOUNTERFILE0.csv"
    age=9999; [ -f "$acf" ] && age=$(( $(date +%s) - $(stat -c %Y "$acf") ))
    read -r _ ins ipc <<<"$(live_ac "$acf")"
    insM=$(awk "BEGIN{printf \"%.1f\", ${ins:-0}/1e6}")
    if   [ "$age" -le 20 ]; then hs=$'\033[32m● running\033[0m'
    elif [ "$age" -le 90 ]; then hs=$'\033[33m… staging\033[0m'
    else hs="$(printf '\033[31m■ idle %ds\033[0m' "$age")"; fi
    L+=("$(printf ' \033[1mFPGA%s\033[0m(%s) %-11s %-5s  %6sM ins  ipc %-6s  %b' "$fid" "${BUS[$fid]}" "$cb" "${fsp:-?}" "$insM" "${ipc:---}" "$hs")")
  done
  L+=("$(printf '\033[2m%*s\033[0m' 70 '' | tr ' ' '-')")
  L+=("$(printf ' \033[1m%-11s %-4s %-7s %s\033[0m' BENCH done w-IPC 'sp0..4  (●ok ▲spin ✗fail ·pend)')")
  divlist=""
  for bd in $(find "$RUN/$CONFIG" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort); do
    bn=$(basename "$bd"); grid=""; nd=0; wsum=0; wipc=0
    wf=$(ls "$BASE"/simpoints/*"$(echo "$bn"|sed 's/-workload[0-9]//')"*.weights 2>/dev/null | head -1)
    for i in 0 1 2 3 4; do
      st="$bd/sp_$i/stats.txt"
      if [ -f "$st" ]; then
        r=$(mark "$st")
        case "$r" in
          ok*) grid+=$'\033[32m●\033[0m '; v=${r#ok }
               w=$(awk -v k="$i" '$2==k{print $1}' "$wf" 2>/dev/null); w=${w:-0.2}
               wsum=$(awk "BEGIN{print $wsum+$w}"); wipc=$(awk "BEGIN{print $wipc+$w*$v}"); nd=$((nd+1));;
          diverged) grid+=$'\033[33m▲\033[0m '; divlist+="$bn:sp$i ";;
          fail*)    grid+=$'\033[31m✗\033[0m ';;
          *)        grid+=$'\033[2m·\033[0m ';;
        esac
      else grid+=$'\033[2m·\033[0m '; fi
    done
    ndone=$(ls "$bd"/sp_*/stats.txt 2>/dev/null | wc -l)
    wtxt="--"; [ "$nd" -gt 0 ] && wtxt=$(awk "BEGIN{printf \"%.3f\", ($wsum>0)?$wipc/$wsum:0}")
    L+=("$(printf ' %-11s %d/5  %-7s %b' "$bn" "$ndone" "$wtxt" "$grid")")
  done
  L+=("$(printf '\033[2m%*s\033[0m' 70 '' | tr ' ' '-')")
  [ -n "$divlist" ] && L+=("$(printf ' \033[33mdiverged(spin)\033[0m: %s' "$divlist")")
  L+=("$(printf ' \033[2mw-IPC excludes diverged simpoints · Ctrl-C to quit (sweep untouched)\033[0m')")

  # in-place redraw: home, print each line clamped to width + clear-to-EOL, then clear below
  printf '\033[H'
  for line in "${L[@]}"; do printf '%.*b\033[K\n' "$((COLS+40))" "$line"; done
  printf '\033[J'
  # wait REFRESH seconds, but exit immediately if the user presses q/Q.
  # (interactive tty only; if stdin is piped/redirected just sleep so we don't busy-loop)
  if [ -t 0 ]; then
    read -rsn1 -t "$REFRESH" key 2>/dev/null && [[ "$key" == [qQ] ]] && break
  else
    sleep "$REFRESH"
  fi
done
