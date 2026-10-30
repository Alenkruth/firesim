# write reports

open_run impl_1

# Report final timing
report_timing_summary -file ${rpt_dir}/final_timing_summary.rpt

# Report utilization
report_utilization -hierarchical -hierarchical_percentages -file ${rpt_dir}/final_utilization.rpt

# Report RAM utilization
report_ram_utilization -include_lutram -file ${rpt_dir}/final_ram_utilization.rpt -csv ${rpt_dir}/final_ram_utilization.csv

# Report clock utilization
report_clock_utilization -file ${rpt_dir}/final_clock_utilization.rpt

# [lean58] timing-audit-20261023 section 7 (owner order 2026-10-23): per-path-family measurement of the core clock
# group, so F1-F6 can be measured instead of estimated.  No RTL change, no extra implementation run.  Every report is
# wrapped in catch: a reporting failure must never stop the bitstream/mcs write below.
proc lean58_report {name body} {
    if {[catch {uplevel 1 $body} err]} {
        puts "CRITICAL WARNING: \[lean58 report\] $name failed (non-fatal): $err"
    } else {
        puts "INFO: \[lean58 report\] $name written"
    }
}
lean58_report clocks { report_clocks -file ${rpt_dir}/final_clocks.rpt }
# The core group is the 30 MHz target clock domain (uart / harnessbinder / reference clocks, period ~33.3 ns);
# selected by period so a renamed clock does not silently drop the report.
set core_clks [get_clocks -quiet -filter {PERIOD > 30.0 && PERIOD < 40.0}]
puts "INFO: \[lean58 report\] core clocks: $core_clks"
if {[llength $core_clks] == 0} {
    puts "CRITICAL WARNING: \[lean58 report\] no clock with a 30-40 ns period: core-group timing report skipped"
} else {
    lean58_report core_timing_200 {
        report_timing -from $core_clks -to $core_clks -max_paths 200 -nworst 1 -unique_pins -sort_by slack \
                      -file ${rpt_dir}/final_timing_core200.rpt
    }
}
lean58_report design_analysis_timing {
    report_design_analysis -timing -max_paths 200 -file ${rpt_dir}/final_design_analysis_timing.rpt
}
lean58_report design_analysis_logic_levels {
    report_design_analysis -logic_level_distribution -logic_level_dist_paths 5000 \
                           -file ${rpt_dir}/final_design_analysis_logic_levels.rpt
}
lean58_report design_analysis_congestion {
    report_design_analysis -congestion -file ${rpt_dir}/final_design_analysis_congestion.rpt
}
lean58_report high_fanout_nets_timing {
    report_high_fanout_nets -timing -load_types -max_nets 200 -file ${rpt_dir}/final_high_fanout_nets.rpt
}
lean58_report utilization_slr {
    report_utilization -slr -file ${rpt_dir}/final_utilization_slr.rpt
}

close_design

# write bit/mcs

set firesim_bit_path ${root_dir}/vivado_proj/firesim.bit

file copy -force ${root_dir}/vivado_proj/firesim.runs/${impl_run}/${top_level_name}.bit ${firesim_bit_path}

write_cfgmem -force -format mcs -interface SPIx4 -size 1024 -loadbit "up 0x01002000 ${firesim_bit_path}" -verbose ${root_dir}/vivado_proj/firesim.mcs
