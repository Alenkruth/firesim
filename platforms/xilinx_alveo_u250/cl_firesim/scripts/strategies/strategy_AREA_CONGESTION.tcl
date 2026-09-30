# AREA + CONGESTION hybrid.  For designs that fail ROUTING (unroutable nets /
# congestion level >= 5) while sitting at high CLB occupancy but moderate LUT
# percentage -- i.e. CLB-bound, not timing-bound.
#
# Why this exists: strategy_TIMING passes -no_lc, which disables LUT combining and
# so deliberately RAISES the LUT count.  On the IFTDMI design LUTs are 62% of the
# device but CLBs are 87%, and it is CLB occupancy that drives congestion, so
# -no_lc spends the exact resource that is scarce.  strategy_AREA drops -no_lc and
# uses AreaOptimized_high, but keeps ExtraNetDelay_high placement, which spreads
# for timing rather than for congestion.  Neither file combines the two.
#
# At 25 MHz (40 ns) timing has enormous slack, so every knob is spent on area and
# routability instead:
#   AreaOptimized_high      - minimise LUT count (the binding resource)
#   no -no_lc               - allow LUT combining
#   control_set_opt_threshold 16 - merge control sets so slices pack denser
#   -muxf_remap/-sweep/...  - opt_design area cleanups (from CONGESTION_IFT)
#   AltSpreadLogic_high     - congestion-aware spreading (the actual failure mode)
#   route_phys_opt 0        - post-route timing cleanup buys nothing at 25 MHz
set synth_options "-shreg_min_size 10 -control_set_opt_threshold 16 -retiming"
set synth_directive "AreaOptimized_high"
set opt 1
# opt_options MUST stay empty when opt_directive is set: Vivado rejects the pair with
#   ERROR: [Common 17-69] Cannot specify additional options with '-directive'.
# The option list here was copied from strategy_CONGESTION_IFT.tcl, which carries the
# same invalid combination but was never selectable (CONGESTION_IFT is absent from the
# BuildStrategy enum in deploy/buildtools/buildconfig.py), so its bug had never fired.
# TIMING and CONGESTION both use empty opt_options with a directive -- match them.
set opt_options    ""
set opt_directive  "ExploreArea"
set place_options    ""
set place_directive  "AltSpreadLogic_high"
set phys_opt 1
set phys_options     ""
set phys_directive   "AggressiveExplore"
set route_options    ""
set route_directive  "Explore"
set route_phys_opt 0
set post_phys_options    ""
set post_phys_directive  "Explore"
