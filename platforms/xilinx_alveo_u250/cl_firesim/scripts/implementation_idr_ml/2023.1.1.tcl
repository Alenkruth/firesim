# Intelligent Design Runs (IDR) Flow
# Clean up any previous IDR run before creating a new one (handles reruns).
# Delete only the parent run (idr_impl_1) — child runs (idr_impl_1_rqs etc.)
# cannot be deleted directly and are cascade-deleted with the parent.
if {[llength [get_runs -quiet idr_impl_1]] > 0} {
    delete_runs [get_runs idr_impl_1]
}
create_run -flow "Vivado IDR Flow $vivado_version_major" -parent_run synth_1 idr_impl_1
set_property REFERENCE_RUN ${impl_run} [get_runs idr_impl_1]
set impl_run [get_runs idr_impl_1]

launch_runs ${impl_run} -jobs ${jobs}
wait_on_run ${impl_run}

# Do not call check_progress here — Vivado 2023.1.1 segfaults in report_qor_assessment
# inside the idr_impl_1_rqs sub-run, causing the parent IDR run to show < 100% progress.
# Instead, warn and fall through to the sub-run timing check below.
set idr_progress [get_property PROGRESS ${impl_run}]
if {$idr_progress != "100%"} {
    puts "WARNING: IDR run did not complete (progress: $idr_progress) - likely Vivado 2023.1.1 segfault in report_qor_assessment; checking sub-runs for any timing-met result"
}

# We need to figure out which IDR implementation run was successful
foreach sub_impl_run [get_runs ${impl_run}*] {
  if {[get_property PROGRESS ${sub_impl_run}] == "100%"} {
    set WNS [get_property STATS.WNS ${sub_impl_run}]
    set WHS [get_property STATS.WHS ${sub_impl_run}]
    if {$WNS >= 0 && $WHS >= 0} {
      puts "INFO: timing met in idr run ${sub_impl_run}"
      break
    }
  }
}
