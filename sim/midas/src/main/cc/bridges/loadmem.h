// See LICENSE for license details.

#ifndef __LOADMEM_H
#define __LOADMEM_H

#include <cstdint>
#include <string>
#include <vector>

#include <gmp.h>

#include "core/config.h"
#include "core/widget.h"

class simif_t;

struct LOADMEMWIDGET_struct {
  uint64_t W_ADDRESS_H;
  uint64_t W_ADDRESS_L;
  uint64_t W_LENGTH;
  uint64_t ZERO_OUT_DRAM;
  uint64_t W_DATA;
  uint64_t ZERO_FINISHED;
  uint64_t R_ADDRESS_H;
  uint64_t R_ADDRESS_L;
  uint64_t R_DATA;
};

class loadmem_t final : public widget_t {
public:
  /// The identifier for the bridge type.
  static char KIND;

  loadmem_t(simif_t &simif,
            const LOADMEMWIDGET_struct &mmio_addrs,
            unsigned index,
            const std::vector<std::string> &args,
            const AXI4Config &mem_conf,
            unsigned mem_data_chunk);

  void read_mem(size_t addr, mpz_t &value);
  void write_mem(size_t addr, mpz_t &value);
  void write_mem_chunk(size_t addr, mpz_t &value, size_t bytes);

  // Debug: read the OpenSBI M-mode trap context off the M-stack derived from
  // mscratch and print it (mepc, mstatus/MPP, all 32 GPRs). Uses the LoadMem
  // DMA read path only -- never halts the hart -- so it is safe to call after
  // a run to inspect whatever trap the firmware last took.
  void dump_trap_regs(uint64_t mscratch);

  // Helper to zero out all DRAM.
  void zero_out_dram();

  // [ZERORANGE 2026-11-10] +zero-out-range=<base>:<len>: write zeros over the target physical range
  // [base, base + len) through the ordinary LoadMem write path (W_ADDRESS/W_LENGTH/W_DATA, the path the
  // ELF load uses), instead of the hardware sweep of all DRAM. base and len must be multiples of 4 KiB,
  // base >= 0x80000000, len <= 256 MiB (beyond that +zero-out-dram is the faster tool). Returns false
  // (and prints why) on a refused range or a non-zero read-back; nothing is written for a refused range.
  // It does NOT mark DRAM as zeroed: +sparse-loadmem stays off (DRAM outside the range is not zero).
  bool zero_mem_range(uint64_t paddr, uint64_t len);

  // Loads the contents of memory from a file.
  void load_mem_from_file(const std::string &filename);

  unsigned get_mem_data_chunk() const { return mem_data_chunk; }

private:
  const LOADMEMWIDGET_struct mmio_addrs;
  const AXI4Config mem_conf;
  const unsigned mem_data_chunk;
  // [SPARSELOAD 2026-11-05] +sparse-loadmem: after zero_out_dram() has run in
  // this launch, ELF segment beats that are all zero are not written (DRAM already
  // holds 0 there). Off unless the plusarg is given AND the zero sweep ran.
  bool skip_zero_requested = false;
  bool dram_zeroed = false;
};

#endif // __LOADMEM_H
