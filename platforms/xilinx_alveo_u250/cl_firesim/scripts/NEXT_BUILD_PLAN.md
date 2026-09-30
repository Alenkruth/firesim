# IFTDMI next-build plan — measured, not guessed  (2026-08-28)

The 2026-08-24 build ran 4d18h and produced NO bitstream. It died at 21:17 when
`idr_impl_1_ml_strat_1` failed `route_design` with

    ERROR: [Route 35-3424] SLL Assignment failed. ILP failed to find solution for cut [0-1]

and the IDR parent propagated that failure, killing `strat_2` and `strat_3` 15 s later.
Both had **0 errors** and were routing normally. They were terminated, not failed.

## 1. The design is SLL-bound, and the demand is IMBALANCED

Capacity is **1440 SLLs per column**, 16 columns per cut. Measured demand:

| run | cut [0-1] peak | cut [2-3] peak | cols 0-3 |
|---|---|---|---|
| strat_1 (FAILED) | 1606 (112%) | 1880 (131%) | 8-10% |
| strat_2 (killed) | 1855 (129%) | 1500 (104%) | 2% |
| strat_3 (killed) | **961 (67%)** | **923 (64%)** | 4-7% |

Total crossings are not the problem; their DISTRIBUTION is. Vivado says so directly:
`[Route 35-3311] The design has high localized SLL routing demand.`
Columns 8-15 run 90-130% while columns 0-3 idle at 2-10%.

## 2. ACTION: delete the SLR0 left-edge exclusion (highest confidence)

`pblocks.tcl` currently keeps `firesim_top` OUT of `CLOCKREGION_X0Y0:X1Y3`. Its stated
reason is protecting PCIe/DDR4 at `PCIE40E4_X0Y1` — read as clock-region column X0.

**That reading is wrong.** `probe_placement.tcl` resolved the PCIe hard block on the
actual placed design:

    site PCIE40E4_X0Y1  ->  CLOCKREGION_X7Y4

A SITE name never gives a clock region. The exclusion reserves empty space on the
OPPOSITE side of the die from the interface it was meant to protect — and with 16 SLL
columns over 8 CR columns (2:1), CR columns X0-X1 are SLL columns 0-3, precisely the
ones measured at 2-10% while the right side overflows. The exclusion is a plausible
CONTRIBUTOR to the imbalance that killed the build.

Set `DROP_SLR0_LEFT_EDGE_EXCLUSION 1` (see pblocks_xdma_prepared.tcl.NOTSOURCED).
Cost if wrong: one build. Evidence it is wrong: measured, twice.

## 3. ACTION: use strat_3's directive set

strat_3 won on BOTH axes and never got to finish:

    WNS +0.010 / TNS 0.000 (post-place)   and   max SLL 67%, nothing near capacity
    directives: AggressiveExplore + EarlyBlockPlacement + ExploreSequentialArea

Compare the losers:
    strat_1  Explore + AggressiveExplore + NoTimingRelaxation      -> SLL 131%, FAILED
    strat_2  AggressiveExplore + ExploreArea + NoTimingRelaxation  -> SLL 129%, WNS -0.223

`EarlyBlockPlacement` is the plausible differentiator: placing the hard blocks first
anchors the SLR-crossing structure before the rest fills in. Run strat_3's set FIRST,
alone, rather than as one of three.

## 4. ACTION: do not let one strategy kill the others

The build lost two healthy runs to one failure. Either run strategies sequentially, or
configure IDR so a failed strategy is skipped rather than fatal. This alone would have
salvaged the 2026-08-24 build.

## 5. RESUMABLE NOW — do this before any full rebuild

Routed/placed checkpoints survived:

    strat_3  .../idr_impl_1_ml_strat_3/*.dcp   newest 08-28 19:48 (494M)   <- best run
    strat_2  .../idr_impl_1_ml_strat_2/*.dcp   newest 08-28 18:28 (491M)

`open_checkpoint` + `route_design` on strat_3's DCP skips synthesis AND placement --
hours, not days -- and answers the only open question: what routing costs a design
that starts at WNS +0.010 with 67% peak SLL. Do this BEFORE spending another 4-day
build on any floorplan change.

## 6. The XDMA anchor: still prepared, still NOT justified by this data

`pblocks_xdma_prepared.tcl.NOTSOURCED` anchors XDMA near PCIe at X7Y4 because 38.6% of
its 142,708 primitives sit in SLR1 columns X0-X3, far from their own hard block. That
addresses TIMING on `xdma_0_axi_aclk`.

It does NOT obviously address SLL, and could make it worse: pulling XDMA rightward adds
mass to exactly the columns already at 90-130%. **Do not arm it together with item 2.**
Change one thing at a time, and measure with `probe_placement.tcl` after each.

## Order of operations

1. Resume strat_3's DCP through `route_design` alone.       (hours)
2. If it closes -> done, no floorplan change needed.
3. If it misses on setup only -> rebuild with item 2 + item 3.
4. If it fails on SLL -> item 2 is then load-bearing; measure with probe first.
5. Keep the XDMA anchor (item 6) in reserve, one variable at a time.
