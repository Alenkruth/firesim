// See LICENSE for license details.

#include "simulation.h"
#include "bridges/clock.h"
#include "bridges/loadmem.h"
#include "bridges/master.h"
#include "core/bridge_driver.h"
#include "core/simif.h"
#include "core/stream_engine.h"
#include "core/timing.h"

#include <cassert>
#include <cerrno>
#include <cinttypes>
#include <cstdio>

simulation_t::simulation_t(widget_registry_t &registry,
                           const std::vector<std::string> &args)
    : registry(registry), clock(registry.get_widget<clockmodule_t>()) {
  bool fastloadmem = false;
  for (auto &arg : args) {
    if (arg.find("+fastloadmem") == 0) {
      fastloadmem = true;
    }
    if (arg.find("+loadmem=") == 0) {
      load_mem_path = arg.c_str() + 9;
    }
    if (arg.find("+zero-out-dram") == 0) {
      do_zero_out_dram = true;
    }
    if (arg.find("+zero-out-range=") == 0) {
      zero_out_range = arg.c_str() + 16;
    }
    if (arg.find("+check-fingerprint") == 0) {
      check_fingerprint_only = true;
    }
    if (arg.find("+write-fingerprint=") == 0) {
      write_fingerprint_only = atoi(arg.c_str() + 19);
    }
    if (arg.find("+dump-mstack=") == 0) {
      dump_mstack_scratch = strtoull(arg.c_str() + 13, nullptr, 0);
    }
  }

  if (fastloadmem)
    load_mem_path.clear();
}

void simulation_t::record_start_times() {
  start_hcycle = clock.hcycle();
  start_time = timestamp();
}

void simulation_t::record_end_times() {
  end_time = timestamp();
  end_tcycle = clock.tcycle();
  end_hcycle = clock.hcycle();
}

void simulation_t::print_simulation_performance_summary() {
  // Must call record_start_times and record_end_times before invoking this
  // function
  assert(start_hcycle.has_value() && end_hcycle.has_value() &&
         "simulation not executed");

  const uint64_t hcycles = *end_hcycle - *start_hcycle;
  const double sim_time = diff_secs(end_time, start_time);
  const double sim_speed = ((double)end_tcycle) / (sim_time * 1000.0);
  const double measured_host_frequency =
      ((double)hcycles) / (sim_time * 1000.0);
  const double fmr = ((double)hcycles / end_tcycle);

  fprintf(stderr, "\nEmulation Performance Summary\n");
  fprintf(stderr, "------------------------------\n");
  fprintf(stderr, "Wallclock Time Elapsed: %.1f s\n", sim_time);
  // Provide enough sig-figs to let the report be useful in RTL sim
  fprintf(stderr, "Host Frequency: ");
  if (measured_host_frequency > 1000.0) {
    fprintf(stderr, "%.3f MHz\n", measured_host_frequency / 1000.0);
  } else {
    fprintf(stderr, "%.3f KHz\n", measured_host_frequency);
  }

  fprintf(stderr, "Target Cycles Emulated: %" PRIu64 "\n", end_tcycle);
  fprintf(stderr, "Effective Target Frequency: ");
  if (sim_speed > 1000.0) {
    fprintf(stderr, "%.3f MHz\n", sim_speed / 1000.0);
  } else {
    fprintf(stderr, "%.3f KHz\n", sim_speed);
  }
  fprintf(stderr, "FMR: %.2f\n", fmr);
  fprintf(stderr,
          "Note: The latter three figures are based on the fastest "
          "target clock.\n");
}

void simulation_t::simulation_init() {
  for (auto *bridge : registry.get_all_bridges()) {
    bridge->init();
  }
}

void simulation_t::simulation_finish() {
  for (auto *bridge : registry.get_all_bridges()) {
    bridge->finish();
  }
}

int simulation_t::execute_simulation_flow() {
  wait_for_init();

  // following fingerprint logic uses 'exit' instead of 'return' to avoid
  // issues w/ deconstructors not having initialized values
  auto &master = registry.get_widget<master_t>();
  if (check_fingerprint_only || write_fingerprint_only.has_value()) {
    if (check_fingerprint_only && write_fingerprint_only.has_value()) {
      fprintf(stderr, "Unable to both check/write FireSim fingerprint\n");
      exit(EXIT_FAILURE);
    }

    if (check_fingerprint_only && master.check_fingerprint()) {
      fprintf(stderr, "Invalid FireSim fingerprint\n");
      exit(EXIT_FAILURE);
    }
    if (write_fingerprint_only.has_value()) {
      master.write_fingerprint(write_fingerprint_only.value());
    }
    exit(EXIT_SUCCESS);
  } else {
    if (master.check_fingerprint()) {
      fprintf(stderr, "Invalid FireSim fingerprint\n");
      exit(EXIT_FAILURE);
    }
  }

  if (auto *fpga_stream = registry.get_fpga_stream_engine()) {
    fpga_stream->init();
  }

  if (auto *stream = registry.get_stream_engine()) {
    stream->init();
  }

  init_dram();

  simulation_init();

  record_start_times();
  fprintf(stderr, "Commencing simulation.\n");
  const int exit_code = simulation_run();
  fprintf(stderr, "\nSimulation complete.\n");
  record_end_times();

  simulation_finish();

  // Debug: after the run, read the OpenSBI M-mode trap context off the M-stack
  // (DMA read via LoadMem -- no halt) to name whatever trap the firmware wedged
  // in. Gated on +dump-mstack=<mscratch>, so normal runs are unaffected.
  if (dump_mstack_scratch.has_value()) {
    if (auto *loadmem = registry.get_widget_opt<loadmem_t>()) {
      fprintf(stderr,
              "Dumping OpenSBI M-stack trap context (mscratch=0x%" PRIx64 ")\n",
              *dump_mstack_scratch);
      loadmem->dump_trap_regs(*dump_mstack_scratch);
    } else {
      fprintf(stderr, "+dump-mstack set but target has no LoadMem widget\n");
    }
  }

  const bool timeout = simulation_timed_out();

  if (exit_code != 0) {
    fprintf(stderr,
            "*** FAILED *** (code = %d) after %" PRIu64 " cycles\n",
            exit_code,
            end_tcycle);
  } else if (timeout) {
    fprintf(stderr,
            "*** FAILED *** simulation timed out after %" PRIu64 " cycles\n",
            end_tcycle);
  } else {
    fprintf(stderr, "*** PASSED *** after %" PRIu64 " cycles\n", end_tcycle);
  }

  print_simulation_performance_summary();

  return timeout ? EXIT_FAILURE : exit_code;
}

void simulation_t::wait_for_init() {
  auto &master = registry.get_widget<master_t>();
  while (!master.is_init_done())
    ;
}

void simulation_t::init_dram() {
  // [ZERORANGE 2026-11-10] +zero-out-range=<base>:<len>: parsed and checked before any DRAM write; a
  // malformed value, or both zeroing plusargs at once, stops the launch here (nothing written).
  uint64_t zr_base = 0, zr_len = 0;
  if (!zero_out_range.empty()) {
    const char *s = zero_out_range.c_str();
    char *e = nullptr;
    errno = 0;
    zr_base = strtoull(s, &e, 16);
    bool ok = (errno == 0 && e != s && *e == ':');
    if (ok) {
      const char *s2 = e + 1;
      zr_len = strtoull(s2, &e, 16);
      ok = (errno == 0 && e != s2 && *e == '\0');
    }
    if (!ok) {
      fprintf(stderr, "[zero-out-range] REFUSED: '+zero-out-range=%s' is not <base>:<len> in hex\n", s);
      exit(EXIT_FAILURE);
    }
    if (do_zero_out_dram) {
      fprintf(stderr, "[zero-out-range] REFUSED: +zero-out-range and +zero-out-dram are mutually exclusive\n");
      exit(EXIT_FAILURE);
    }
  }
  if (auto *loadmem = registry.get_widget_opt<loadmem_t>()) {
    if (!zero_out_range.empty() && !loadmem->zero_mem_range(zr_base, zr_len))
      exit(EXIT_FAILURE);
    if (do_zero_out_dram) {
      fprintf(stderr,
              "Zeroing out FPGA DRAM. This will take a few seconds...\n");
      loadmem->zero_out_dram();
    }

    if (!load_mem_path.empty()) {
      loadmem->load_mem_from_file(load_mem_path);
    }
  } else {
    if (do_zero_out_dram || !zero_out_range.empty() || !load_mem_path.empty()) {
      fprintf(stderr,
              "Skipping memory initialization: target does not use DRAM\n");
    }
  }
}
