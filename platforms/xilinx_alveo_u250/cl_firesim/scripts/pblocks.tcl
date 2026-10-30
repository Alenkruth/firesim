# Placement hints for IFT BOOM builds on U250
# Applied via STEPS.PLACE_DESIGN.TCL.PRE before place_design.
# Guards on cell existence make this a no-op for non-IFT designs.
#
# U250 clock region layout (verified from get_clock_regions on xcu250-figd2104-2L-e):
#   SLR0 = CLOCKREGION_X0Y0:CLOCKREGION_X7Y3
#   SLR1 = CLOCKREGION_X0Y4:CLOCKREGION_X7Y7
#   SLR2 = CLOCKREGION_X0Y8:CLOCKREGION_X7Y11
#   SLR3 = CLOCKREGION_X0Y12:CLOCKREGION_X7Y15



set boom_root "firesim_top/top/sim/target/FireSim_/chiptop0/system/tile_prci_domain/element_reset_domain_boom_tile"

# pBlock: soft-constrain CSR to SLR1/SLR2 boundary
# CSR drives both LSU (SLR2) and ROB influencer logic; anchoring it at the
# SLR1/SLR2 boundary reduces hop distance to both.
# ── floorplan constraints: ALL DISABLED 2026-08-30 ───────────────────────────
# impl_1 failed to ROUTE after 8h53m with these on:
#   [Route 35-162] 316 signals failed to route due to routing congestion
#   [Route 35-2]   Design is not legally routed. There are 184 node overlaps.
# The previous build, with no floorplan constraints, routed successfully and failed
# only on TIMING.  Constraining placement on a design already at 61% LUT removed
# freedom where congestion was worst, trading a timing failure for an unroutable
# one.  Let the placer choose.  Re-enable one at a time, soft first, and only with
# evidence that routing still closes.
set ENABLE_CSR_PBLOCK 0
set ENABLE_RAS_PBLOCK 0

set csr_cells [get_cells -quiet -hierarchical -filter "NAME =~ ${boom_root}/core/csr*"]
if {$ENABLE_CSR_PBLOCK && [llength $csr_cells] > 0} {
    create_pblock pblock_csr
    add_cells_to_pblock [get_pblocks pblock_csr] $csr_cells
    resize_pblock [get_pblocks pblock_csr] -add {CLOCKREGION_X3Y7:CLOCKREGION_X6Y8}
    set_property IS_SOFT 1 [get_pblocks pblock_csr]
    puts "INFO: pblock_csr created (SLR1/2 boundary, soft)"
}

# pBlock: soft-constrain RAS to lower SLR2
# ras_secret_N_reg_0 signals dominate phys_opt improvement candidates;
# keeping RAS co-located with frontend/FTQ reduces SLR crossing on those paths.
set ras_cells [get_cells -quiet -hierarchical -filter "NAME =~ ${boom_root}/frontend/ras*"]
if {$ENABLE_RAS_PBLOCK && [llength $ras_cells] > 0} {
    create_pblock pblock_ras
    add_cells_to_pblock [get_pblocks pblock_ras] $ras_cells
    resize_pblock [get_pblocks pblock_ras] -add {CLOCKREGION_X0Y8:CLOCKREGION_X3Y9}
    set_property IS_SOFT 1 [get_pblocks pblock_ras]
    puts "INFO: pblock_ras created (lower SLR2, soft)"
}

# EQUIVALENT_DRIVER_OPT MERGE: de-replicate over-replicated high-fanout cells
# in congested SLR2 regions (per Vivado RQS-CONG-9 from stage1_congestion_suggestions.rqs).
# Patterns use trailing * only — no bit indices — to avoid Vivado filter treating
# escaped brackets as character classes instead of literal [ ] characters.
set merge_patterns [list \
    "${boom_root}/lsu/stq_execute_head_reg*" \
    "${boom_root}/core/rename_stage/r_uop_cf_op_count_id_reg*" \
    "${boom_root}/core/rob/rob_head_reg*" \
    "${boom_root}/core/rob/rob_tail_reg*" \
    "${boom_root}/core/alu_exe_unit/ALUUnit/r_uops_0_rob_idx_reg*" \
    "${boom_root}/core/alu_exe_unit_1/ALUUnit/r_uops_0_rob_idx_reg*" \
]
set merge_cells {}
foreach pat $merge_patterns {
    set found [get_cells -quiet -hierarchical -filter "NAME =~ $pat"]
    foreach cell $found {
        # Skip _rep/_rep__N copies: EQUIVALENT_DRIVER_OPT is only valid on original cells
        if {[string first "_rep" $cell] == -1} {
            lappend merge_cells $cell
        }
    }
}
if {[llength $merge_cells] > 0} {
    if {[catch {set_property EQUIVALENT_DRIVER_OPT MERGE $merge_cells} err]} {
        puts "WARNING: EQUIVALENT_DRIVER_OPT MERGE failed (non-fatal): $err"
    } else {
        puts "INFO: EQUIVALENT_DRIVER_OPT MERGE applied to [llength $merge_cells] cells"
    }
}

# ---------------------------------------------------------------------------
# [F2a] lean58 (timing-audit-20261023 section 6, F2 (a); owner order 2026-10-23): replicate the drivers of the D$
# reconfiguration registers cfg_set_applied / cfg_way_applied (dcache.scala, ENABLE_RECONF).  lean57's worst path
# (core group +2.716 ns, all 10 worst paths) starts at dcache/cfg_set_applied_reg[0], fan-out 148, with a 3.64 ns
# first net across SLR2 to the MSHR rpq idx-match LUTs.  They change only on a 0xbc1 reconfiguration.  No RTL
# change: FORCE_MAX_FANOUT makes phys_opt_design (enabled in strategy TIMING, directive AggressiveExplore)
# replicate the driver so no copy drives more than 16 loads, placed near its loads; MAX_FANOUT carries the same
# limit for any later fan-out optimization.  Functionally exact (replicas are copies of the same flop).
# Guarded (-quiet) and loud: a no-op prints a CRITICAL WARNING, never an error (a TCL error here kills the run).
# ---------------------------------------------------------------------------
set ENABLE_DCFG_FANOUT 1
set dcfg_fanout 16
if {$ENABLE_DCFG_FANOUT} {
    set dcfg_regs [get_cells -quiet -hierarchical -filter \
        "NAME =~ ${boom_root}/*cfg_set_applied_reg* || NAME =~ ${boom_root}/*cfg_way_applied_reg*"]
    # keep the D$ copies only (other modules have their own cfg_*_applied registers)
    set dcfg_d {}
    foreach c $dcfg_regs { if {[string match "*dcache*" $c]} { lappend dcfg_d $c } }
    set dcfg_nets [get_nets -quiet -of_objects [get_pins -quiet -of_objects $dcfg_d -filter {DIRECTION == OUT && REF_PIN_NAME == Q}]]
    if {[llength $dcfg_nets] == 0} {
        puts "CRITICAL WARNING: \[F2a\] no dcache cfg_set_applied/cfg_way_applied nets matched -- fan-out limit NOT applied"
    } elseif {[catch {
        set_property FORCE_MAX_FANOUT $dcfg_fanout $dcfg_nets
        set_property MAX_FANOUT $dcfg_fanout $dcfg_nets
    } err]} {
        puts "CRITICAL WARNING: \[F2a\] setting FORCE_MAX_FANOUT failed (non-fatal): $err"
    } else {
        puts "INFO: \[F2a\] FORCE_MAX_FANOUT/MAX_FANOUT $dcfg_fanout on [llength $dcfg_nets] nets of [llength $dcfg_d] dcache cfg registers"
        foreach n $dcfg_nets { puts "INFO: \[F2a\]   $n fanout=[get_property FLAT_PIN_COUNT $n]" }
    }
}

# 2026-08-23: SLR0 left-edge exclusion for the IFTDMI build.
# The May IFTDMI build failed timing with ALL 56 violations in PCIe4/DDR4 hard IP (0 logic
# levels = pure routing) — BOOM logic crowded onto SLR0's left edge (PCIE40E4_X0Y1,
# HPIOBDIFFINBUF_X0Y84), starving the hard-IP interfaces. Keep firesim_top OUT of the
# left two columns of SLR0 (CLOCKREGION_X0Y0:X1Y3) so the router has room for the
# PCIe/DDR4 nets. Soft so it never makes the design unplaceable; combined with the
# CONGESTION strategy's AltSpreadLogic this relieves the SLR-crossing demand.
# Guard: only applies when firesim_top exists (no-op for other designs).
# 2026-08-29: DISABLED.  The justification above is wrong and the exclusion is harmful.
#
#   The site name PCIE40E4_X0Y1 was read as clock-region column X0.  A SITE NAME DOES
#   NOT GIVE A CLOCK REGION: probe_placement.tcl resolved the PCIe hard block to
#   CLOCKREGION_X7Y4 -- the OPPOSITE edge of the die.  So this pblock reserved SLL
#   columns 0-3 (measured 2-10% utilised) eight clock-region columns away from the
#   interface it was meant to protect, while columns 8-15 ran 90-130%.
#
#   Measured head-to-head, identical RTL, 2026-08-29 floorplan sweep:
#       exclusion ON  (A0): post-route WNS -3.489, TNS -29071.9, WHS -0.123, 48387 failing
#       exclusion OFF (A1): post-route WNS -1.148, TNS   -379.2, WHS +0.001,   868 failing
#   A0 also broke HOLD, which is the harder violation.  Turning it off is worth 2.3ns of
#   WNS and 56x fewer failing endpoints.
#
#   The real fix for the PCIe/DDR4 crowding this was aiming at is pblock_xdma below,
#   which anchors XDMA *at* the PCIe block instead of clearing space away from it.
set ENABLE_FT_BODY_PBLOCK 0
set ft_cells [get_cells -quiet -hierarchical -filter "NAME =~ firesim_top"]
if {$ENABLE_FT_BODY_PBLOCK && [llength $ft_cells] > 0} {
    create_pblock pblock_ft_body
    add_cells_to_pblock [get_pblocks pblock_ft_body] $ft_cells
    resize_pblock [get_pblocks pblock_ft_body] -add {CLOCKREGION_X2Y0:CLOCKREGION_X7Y3}
    resize_pblock [get_pblocks pblock_ft_body] -add {CLOCKREGION_X0Y4:CLOCKREGION_X7Y15}
    set_property IS_SOFT 1 [get_pblocks pblock_ft_body]
    puts "INFO: pblock_ft_body created (SLR0 left-edge X0:X1 excluded, soft)"
} else {
    puts "INFO: pblock_ft_body DISABLED (see comment: it reserved the far side of the die)"
}

# ---------------------------------------------------------------------------
# XDMA anchor -- the actual timing fix.
#
# EVIDENCE (probe_placement.tcl, 2026-08-28; and the A1B0 post-route report):
#   The ONLY clocks with failing endpoints are xdma_0_axi_aclk (250 MHz, -0.323,
#   263 failing of 153,066) and GTYE4_CHANNEL_TXOUTCLK[3] (-0.204, 52 failing).
#   EVERY design clock -- mmcm_clkout0, mmcm_clkout0_1, pll_clk[*], the 300 MHz
#   inputs -- passes with ZERO failing endpoints.  No DDR/MIG clock fails at all,
#   which is why there is no memory-controller pblock here: nothing indicates one.
#
#   The failing nets sit inside xdma_0/inst/udma_wr* and pcie4_*, i.e. inside
#   Xilinx's encrypted IP.  They cannot be retimed or restructured -- only placed
#   better.  XDMA's 142,708 primitives are currently spread across ALL 32 clock
#   regions of SLR1, with 38.6% (55,088 cells, including 7,616 at X0Y7) sitting in
#   columns X0-X3, up to eight CR columns from their own PCIe block at X7Y4.
#   CONGESTION's AltSpreadLogic_medium spread the one block that needed to stay compact.
#
#   Sizing: xdma_0 is 74,976 LUTs (4.34% of device).  A 4x4 clock-region window is
#   ~216k LUTs -> ~35% fill, and already holds 61.4% of XDMA today.  This is feasible
#   where doc 12 ruled containment pblocks IMPOSSIBLE: that finding was about
#   containing BOOM/IFT (144% of two dies), not a 4.34% IP.
#
#   HARD (IS_SOFT 0) deliberately: a soft pblock is a hint the placer may ignore, and
#   being ignored is precisely the failure being fixed.  No EXCLUDE_PLACEMENT, so no
#   capacity is taken away from the rest of the design.
# ---------------------------------------------------------------------------
# DISABLED 2026-08-30.  With this pblock ON, impl_1 failed to ROUTE after 8h53m:
#   [Route 35-162] 316 signals failed to route due to routing congestion
#   [Route 35-2]   Design is not legally routed. There are 184 node overlaps.
# The previous build (no XDMA pblock) routed successfully and failed only on
# TIMING (xdma_0_axi_aclk -0.323).  Hard-constraining 145,922 cells into
# CLOCKREGION_X4Y4:X7Y7 on a design already at 61% LUT removed routing freedom in
# exactly the region that was most congested, trading a timing failure for an
# unroutable one.  Let the placer choose; revisit only with a SOFT pblock and
# evidence that routing still closes.
set ENABLE_XDMA_PBLOCK 0
if {$ENABLE_XDMA_PBLOCK} {
    set xdma_cells [get_cells -quiet -hierarchical -filter {NAME =~ *xdma_0/inst*}]
    if {[llength $xdma_cells] == 0} {
        puts "CRITICAL WARNING: XDMA pblock armed but no xdma_0/inst cells matched -- NO-OP"
    } else {
        # Derive the region from the PLACED PCIe hard block rather than hardcoding --
        # hardcoding a misread column is what created pblock_ft_body.
        set cr_col ""; set cr_row ""
        set pcie_sites [get_sites -quiet -of_objects \
                          [get_cells -quiet -hierarchical -filter {REF_NAME =~ PCIE40E4*}]]
        if {[llength $pcie_sites] > 0} {
            set cr [get_clock_regions -quiet -of_objects [lindex $pcie_sites 0]]
            if {[llength $cr] > 0 && [regexp {X(\d+)Y(\d+)} [lindex $cr 0] -> cc rr]} {
                set cr_col $cc; set cr_row $rr
                puts "INFO: PCIe resolved to CLOCKREGION_X${cc}Y${rr} (derived)"
            }
        }
        if {$cr_col eq ""} {
            set cr_col 7; set cr_row 4    ;# measured 2026-08-28; see header
            puts "CRITICAL WARNING: could not derive PCIe clock region -- using X7Y4"
        }
        set col_hi $cr_col
        set col_lo [expr {$cr_col - 3}]; if {$col_lo < 0} { set col_lo 0 }
        set row_lo [expr {($cr_row / 4) * 4}]
        set row_hi [expr {$row_lo + 3}]
        set region "CLOCKREGION_X${col_lo}Y${row_lo}:CLOCKREGION_X${col_hi}Y${row_hi}"
        create_pblock pblock_xdma
        add_cells_to_pblock [get_pblocks pblock_xdma] $xdma_cells
        resize_pblock [get_pblocks pblock_xdma] -add $region
        set_property IS_SOFT 0 [get_pblocks pblock_xdma]
        puts "INFO: pblock_xdma created over $region ([llength $xdma_cells] cells, HARD)"
    }
}

# ---------------------------------------------------------------------------
# NARROW XDMA interface pblock -- ENABLED for all U250 builds (owner 2026-10-27, "All future builds").
#
# This is NOT pblock_xdma above (all ~145k xdma_0/inst cells in X4Y4:X7Y7; unroutable 2026-08-30, stays
# disabled).  It holds only the soft leaf cells of xdma_0/inst/pcie4_ip_i (PCIe4 wrapper: pipe_inst incl.
# pcie4_0_512b_intfc_mod, gt_top_i soft logic; ~41k cells = ~10.9k LUT + 25k FF + 22 BRAM), HARD, in the
# 2x2 clock regions at the PCIe hard block (PCIE40E4_X0Y1 -> X7Y4, so X6Y4:X7Y5 = SLR1).  LOC'd hard blocks
# (PCIE40E4, GTYE4, BUFG*, IBUFDS*) are left out; the DMA engine (udma_*) and AXI logic stay free.  No
# EXCLUDE_PLACEMENT, so other logic may still use the region.
# Why: v3_2 failed timing because the 512b interface flops (2 ns TXOUTCLK[3]_3 paths into PCIE40E4 SAXIS*)
# were placed in SLR0 and crossed SLR0/SLR1 twice; all 13 passing builds had them in SLR1 Y246-316
# (task-reports/v3_2-timing-rootcause-20261027.md e5b4b659, slr-split-why-20261027.md 161e7750).  The v3_2
# re-implementation with exactly this pblock met timing (WNS 0.007, WHS 0.009; pblock CLB LUT 27%, FF 25%).
# Same filter/region code as phase4/v3_2-pblock/scripts/pblock_xdma_intfc.tcl (3d59d655); only the abort
# paths are changed to loud CRITICAL WARNINGs (an error in this TCL.PRE hook fails the impl/IDR run).
# The shell BD (xdma_0) is identical for every recipe, so IFT, baseline and reconf builds all get it.
# ---------------------------------------------------------------------------
set ENABLE_XDMA_INTFC_PBLOCK 1
if {$ENABLE_XDMA_INTFC_PBLOCK} {
    set _xi_ok 1
    if {[llength [get_pblocks -quiet pblock_xdma_intfc]] > 0} {
        # IDR/RQS hooks re-source this file; a dcp that already carries the pblock keeps it as is
        puts "INFO: \[xdma_intfc\] pblock_xdma_intfc already present ([llength [get_cells -quiet -of_objects [get_pblocks pblock_xdma_intfc]]] cells) -- kept"
        set _xi_ok 0
    } elseif {[llength [get_pblocks -quiet pblock_xdma]] > 0} {
        puts "CRITICAL WARNING: \[xdma_intfc\] pblock_xdma (the wide anchor) is enabled and already owns these cells -- pblock_xdma_intfc NOT APPLIED"
        set _xi_ok 0
    }
    if {$_xi_ok} {
        set pipe_pat {design_1_i/xdma_0/inst/pcie4_ip_i/*}
        # leaf, not LOC-fixed, not the hard block / GT / clock buffers
        set intfc_cells [get_cells -quiet -hierarchical -filter \
            "NAME =~ $pipe_pat && IS_PRIMITIVE && REF_NAME !~ PCIE40E4* && REF_NAME !~ GTYE4* && REF_NAME !~ BUFG* && REF_NAME !~ IBUFDS*"]
        set keep {}
        if {[llength $intfc_cells] > 0} {
            foreach c $intfc_cells l [get_property -quiet LOC $intfc_cells] {
                if {$l eq ""} { lappend keep $c }
            }
        }
        set intfc_cells $keep
        set n512 [llength [lsearch -all -glob $intfc_cells *pcie4_0_512b_intfc_mod*]]
        if {[llength $intfc_cells] == 0} {
            puts "CRITICAL WARNING: \[xdma_intfc\] no cell matched $pipe_pat (netlist has no U250 XDMA) -- pblock_xdma_intfc NOT APPLIED"
            set _xi_ok 0
        } elseif {$n512 == 0} {
            puts "CRITICAL WARNING: \[xdma_intfc\] no pcie4_0_512b_intfc_mod cell among [llength $intfc_cells] matches (XDMA hierarchy changed) -- pblock_xdma_intfc NOT APPLIED"
            set _xi_ok 0
        }
    }
    if {$_xi_ok} {
        # Region from the LOC'd PCIe hard block (measured CLOCKREGION_X7Y4 on 2026-08-28)
        set cr_col ""; set cr_row ""
        set pcie_sites [get_sites -quiet -of_objects \
                          [get_cells -quiet -hierarchical -filter {REF_NAME =~ PCIE40E4*}]]
        if {[llength $pcie_sites] > 0} {
            set cr [get_clock_regions -quiet -of_objects [lindex $pcie_sites 0]]
            if {[llength $cr] > 0 && [regexp {X(\d+)Y(\d+)} [lindex $cr 0] -> cc rr]} {
                set cr_col $cc; set cr_row $rr
                puts "INFO: \[xdma_intfc\] PCIe [lindex $pcie_sites 0] -> CLOCKREGION_X${cc}Y${rr} (derived)"
            }
        }
        if {$cr_col eq ""} {
            set cr_col 7; set cr_row 4
            puts "CRITICAL WARNING: \[xdma_intfc\] could not derive the PCIe clock region -- using X7Y4"
        }
        # 2 columns wide (towards the die centre), 2 rows tall, kept inside the PCIe's SLR (4 CR rows per SLR on U250)
        set col_hi $cr_col
        set col_lo [expr {$cr_col > 0 ? $cr_col - 1 : 0}]
        set slr_lo [expr {($cr_row / 4) * 4}]
        set slr_hi [expr {$slr_lo + 3}]
        if {$cr_row + 1 <= $slr_hi} {
            set row_lo $cr_row; set row_hi [expr {$cr_row + 1}]
        } else {
            set row_lo [expr {$cr_row - 1}]; set row_hi $cr_row
        }
        set region "CLOCKREGION_X${col_lo}Y${row_lo}:CLOCKREGION_X${col_hi}Y${row_hi}"
        if {[catch {
            create_pblock pblock_xdma_intfc
            add_cells_to_pblock [get_pblocks pblock_xdma_intfc] $intfc_cells
            resize_pblock [get_pblocks pblock_xdma_intfc] -add $region
            set_property IS_SOFT 0 [get_pblocks pblock_xdma_intfc]
        } err]} {
            catch {delete_pblocks [get_pblocks -quiet pblock_xdma_intfc]}
            puts "CRITICAL WARNING: \[xdma_intfc\] creating pblock_xdma_intfc failed (non-fatal, removed): $err -- NOT APPLIED"
        } else {
            puts "INFO: \[xdma_intfc\] pblock_xdma_intfc HARD over $region: [llength $intfc_cells] cells ($n512 in pcie4_0_512b_intfc_mod)"
            if {[llength $intfc_cells] > 90000} {
                puts "CRITICAL WARNING: \[xdma_intfc\] [llength $intfc_cells] cells is far above the expected ~41k -- check the filter"
            }
            array unset _rt
            foreach g [get_property PRIMITIVE_GROUP $intfc_cells] { incr _rt($g) }
            foreach k [lsort [array names _rt]] { puts "INFO: \[xdma_intfc\]   $k: $_rt($k)" }
        }
    }
}

# ---------------------------------------------------------------------------
# Loud summary: a silent no-op here cost a full 14h build on 2026-08-25.
# Never errors out (would kill a multi-hour run) -- just makes failure visible.
# ---------------------------------------------------------------------------
set _pb [get_pblocks -quiet]
puts "INFO: ===== PBLOCK SUMMARY ====="
puts "INFO: pblocks present: [llength $_pb] -> $_pb"
foreach _n {pblock_csr pblock_ras pblock_xdma pblock_xdma_intfc} {
    if {[lsearch -exact $_pb $_n] < 0} {
        puts "CRITICAL WARNING: PBLOCK NOT APPLIED: $_n (cell filter matched nothing)"
    } else {
        puts "INFO: PBLOCK OK: $_n cells=[llength [get_cells -quiet -hierarchical -of_objects [get_pblocks $_n]]]"
    }
}
puts "INFO: ===== END PBLOCK SUMMARY ====="
