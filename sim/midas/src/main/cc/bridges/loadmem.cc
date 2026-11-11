// See LICENSE for license details.

#include "loadmem.h"

#include <chrono>
#include <cinttypes>
#include <elf.h>
#include <fstream>
#include <cstring>
#include <cstdlib>

#include "core/simif.h"

char loadmem_t::KIND;

loadmem_t::loadmem_t(simif_t &simif,
                     const LOADMEMWIDGET_struct &mmio_addrs,
                     unsigned index,
                     const std::vector<std::string> &args,
                     const AXI4Config &mem_conf,
                     unsigned mem_data_chunk)
    : widget_t(simif, &KIND), mmio_addrs(mmio_addrs), mem_conf(mem_conf),
      mem_data_chunk(mem_data_chunk) {
  assert(index == 0 && "only one loadmem widget is allowed");
  for (auto &arg : args) {
    if (arg.find("+sparse-loadmem") == 0)
      skip_zero_requested = true;
  }
}

// Load a sparse ELF file by writing each PT_LOAD segment directly via DMA.
// addr argument is relative to DRAM base (offset 0 = physical 0x80000000).
static const uint64_t DRAM_BASE = 0x80000000ULL;

void loadmem_t::load_mem_from_file(const std::string &filename) {
  fprintf(stdout, "[loadmem] start loading file: %s\n", filename.c_str());

  // Detect ELF by magic bytes.
  {
    std::ifstream probe(filename, std::ios::binary);
    if (!probe) {
      fprintf(stderr, "[loadmem] cannot open %s\n", filename.c_str());
      exit(EXIT_FAILURE);
    }
    unsigned char magic[4] = {0};
    probe.read(reinterpret_cast<char*>(magic), 4);
    if (magic[0] == 0x7f && magic[1] == 'E' && magic[2] == 'L' && magic[3] == 'F') {
      fprintf(stdout, "[loadmem] detected ELF format, loading PT_LOAD segments\n");
      std::ifstream elf(filename, std::ios::binary);
      // Read ELF64 header.
      Elf64_Ehdr ehdr;
      elf.read(reinterpret_cast<char*>(&ehdr), sizeof(ehdr));
      fprintf(stdout, "[loadmem] %u program headers\n", ehdr.e_phnum);

      // Read the first 8 bytes at a DRAM offset through the loadmem read path.
      // CAVEAT: on any bitstream built before the LoadMem.scala rAddrH fix, the
      // widget drops the high address bits, so a probe at offset >= 4 GiB actually
      // reads (offset & 0xffffffff). Only offsets below 4 GiB are trustworthy there.
      auto probe8 = [&](uint64_t off, uint8_t out[8]) {
        mpz_t rb;
        mpz_init(rb);
        read_mem(off, rb);
        size_t nw = 0;
        uint32_t *rw =
            (uint32_t *)mpz_export(nullptr, &nw, -1, sizeof(uint32_t), 0, 0, rb);
        for (size_t b = 0; b < 8; b++) {
          size_t w = b / 4;
          out[b] = (rw && w < nw) ? (uint8_t)((rw[w] >> (8 * (b % 4))) & 0xff) : 0;
        }
        mpz_clear(rb);
      };

      // Diagnostics gate (OFF by default): the per-segment offset-0 PROBE and the
      // post-loop VERIFY self-check below were the 0x1e-corruption probe, resolved by
      // the LoadMem.scala rAddrH fix. Set LOADMEM_VERIFY=1 in the env to re-enable.
      const bool lm_verify = (std::getenv("LOADMEM_VERIFY") != nullptr);

      // [SPARSELOAD 2026-11-05] Skip all-zero beats only when this launch zeroed
      // DRAM first (+zero-out-dram ran before us, simulation.cc init_dram), so the
      // resulting DRAM image is byte-identical to a full load. The LoadMem W_DATA
      // path is MMIO-bound (~275 ns per 32-bit word measured on card 5e), so the
      // saving is the zero-beat fraction of the image.
      const bool skip_zero = skip_zero_requested && dram_zeroed;
      if (skip_zero_requested && !dram_zeroed)
        fprintf(stdout, "[loadmem] +sparse-loadmem ignored: DRAM was not zeroed in this launch\n");
      const size_t beat_bytes = (size_t)mem_data_chunk * sizeof(uint32_t);
      uint64_t beats_total = 0, beats_skipped = 0;

      for (int i = 0; i < ehdr.e_phnum; i++) {
        Elf64_Phdr phdr;
        elf.seekg(ehdr.e_phoff + i * ehdr.e_phentsize);
        elf.read(reinterpret_cast<char*>(&phdr), sizeof(phdr));
        if (phdr.p_type != PT_LOAD) continue;
        if (phdr.p_filesz == 0) continue;
        uint64_t paddr = phdr.p_paddr;
        if (paddr < DRAM_BASE) {
          fprintf(stderr, "[loadmem] skipping segment at 0x%lx (below DRAM base)\n", paddr);
          continue;
        }
        uint64_t offset = paddr - DRAM_BASE;
        fprintf(stdout, "[loadmem] segment paddr=0x%lx offset=0x%lx filesz=0x%lx\n",
                paddr, offset, phdr.p_filesz);
        // Read segment data in 4KB chunks and write via write_mem_chunk.
        const size_t chunk_bytes = 4096;
        std::vector<uint8_t> buf(chunk_bytes, 0);
        elf.seekg(phdr.p_offset);
        uint64_t remaining = phdr.p_filesz;
        uint64_t cur_offset = offset;
        mpz_t mpz_buf;
        mpz_init(mpz_buf);
        while (remaining > 0) {
          size_t to_read = std::min((uint64_t)chunk_bytes, remaining);
          std::fill(buf.begin(), buf.end(), 0);
          elf.read(reinterpret_cast<char*>(buf.data()), to_read);
          if (skip_zero && (cur_offset % beat_bytes) == 0) {
            // Write each maximal run of beats that hold a nonzero byte; zero beats
            // are left as the zero sweep wrote them. A partial last beat is padded
            // with zeros by write_mem_chunk exactly as in the full path.
            const size_t nbeats = (to_read + beat_bytes - 1) / beat_bytes;
            auto beat_nonzero = [&](size_t b) {
              const size_t lo = b * beat_bytes;
              const size_t hi = std::min(to_read, lo + beat_bytes);
              for (size_t k = lo; k < hi; k++)
                if (buf[k]) return true;
              return false;
            };
            size_t b = 0;
            while (b < nbeats) {
              if (!beat_nonzero(b)) { b++; beats_skipped++; continue; }
              size_t e = b + 1;
              while (e < nbeats && beat_nonzero(e)) e++;
              const size_t lo = b * beat_bytes;
              const size_t hi = std::min(to_read, e * beat_bytes);
              mpz_import(mpz_buf, hi - lo, -1, 1, 0, 0, buf.data() + lo);
              write_mem_chunk(cur_offset + lo, mpz_buf, hi - lo);
              b = e;
            }
            beats_total += nbeats;
          } else {
            mpz_import(mpz_buf, to_read, -1, 1, 0, 0, buf.data());
            write_mem_chunk(cur_offset, mpz_buf, to_read);
            beats_total += (to_read + beat_bytes - 1) / beat_bytes;
          }
          cur_offset += to_read;
          remaining -= to_read;
        }
        mpz_clear(mpz_buf);

        // Offset 0 (the M-mode firmware, and tohost/fromhost) reads back as 0x1e
        // instead of the image. Re-probe it after EVERY segment so the corruption is
        // attributed to an exact write: if it is already wrong right after segment 0,
        // segment 0's own write never landed; if it turns wrong only after a later
        // segment, that segment's address is aliasing down onto offset 0.
        if (lm_verify) {
          uint8_t z[8];
          probe8(0, z);
          fprintf(stdout,
                  "[loadmem] PROBE offset=0 after segment %d (paddr=0x%lx):",
                  i, paddr);
          for (size_t b = 0; b < 8; b++) fprintf(stdout, " %02x", z[b]);
          fprintf(stdout, "\n");
        }
      }
      // Self-check: read back the first bytes of each PT_LOAD through the SAME
      // loadmem widget we just wrote through. This runs before the hart executes, so
      // it isolates "the DMA write landed in DRAM" from any cache/coherence or
      // debug-module read-path question. Probing the target showed segment 0
      // (0x80000000) reading back as 0x1e/0x01 instead of the image, while a segment
      // at 0x100c00000 read back byte-exact -- this pins down which side is wrong.
      if (lm_verify) {
        elf.clear();
        for (int i = 0; i < ehdr.e_phnum; i++) {
          Elf64_Phdr vph;
          elf.seekg(ehdr.e_phoff + i * ehdr.e_phentsize);
          elf.read(reinterpret_cast<char*>(&vph), sizeof(vph));
          if (vph.p_type != PT_LOAD || vph.p_filesz == 0) continue;
          if (vph.p_paddr < DRAM_BASE) continue;
          uint8_t expect[8] = {0};
          elf.seekg(vph.p_offset);
          elf.read(reinterpret_cast<char*>(expect), sizeof(expect));
          mpz_t rb;
          mpz_init(rb);
          read_mem(vph.p_paddr - DRAM_BASE, rb);
          size_t nw = 0;
          uint32_t *rw = (uint32_t *)mpz_export(nullptr, &nw, -1, sizeof(uint32_t), 0, 0, rb);
          uint8_t got[8] = {0};
          for (size_t b = 0; b < sizeof(got); b++) {
            size_t w = b / 4;
            got[b] = (w < nw) ? (uint8_t)((rw[w] >> (8 * (b % 4))) & 0xff) : 0;
          }
          bool match = true;
          for (size_t b = 0; b < sizeof(got); b++) if (got[b] != expect[b]) match = false;
          // A read at offset >= 4 GiB is only meaningful once the widget honours
          // The >=4GiB read path is fixed (LoadMem.scala rAddrH) and present in the
          // flashed bitstream: the 0x85cc00000 segment reads back byte-exact. An old
          // caveat here reported such segments as "UNVERIFIABLE" even when got==expect,
          // which hid a real PASS behind a scary label. Report the actual comparison.
          fprintf(stdout, "[loadmem] VERIFY paddr=0x%lx expect=", (uint64_t)vph.p_paddr);
          for (size_t b = 0; b < sizeof(expect); b++) fprintf(stdout, "%02x ", expect[b]);
          fprintf(stdout, " got=");
          for (size_t b = 0; b < sizeof(got); b++) fprintf(stdout, "%02x ", got[b]);
          fprintf(stdout, " %s\n", match ? "OK" : "**MISMATCH**");
          mpz_clear(rb);
        }
      }
      if (skip_zero)
        fprintf(stdout, "[loadmem] sparse-loadmem: %" PRIu64 " of %" PRIu64 " beats were zero and not written\n",
                beats_skipped, beats_total);
      fprintf(stdout, "[loadmem] ELF load done\n");
      return;
    }
  }

  // Fall through to original hex format loading.
  std::ifstream file(filename.c_str());
  if (!file) {
    fprintf(stderr, "[loadmem] cannot open %s\n", filename.c_str());
    exit(EXIT_FAILURE);
  }

  const size_t chunk = mem_conf.data_bits / 4;
  fprintf(stdout, "[loadmem] start loading hex, chunk = %ld\n", chunk);

  size_t addr = 0;
  std::string line;
  mpz_t data;
  mpz_init(data);
  while (std::getline(file, line)) {
    assert(line.length() % chunk == 0);
    for (int j = line.length() - chunk; j >= 0; j -= chunk) {
      mpz_set_str(data, line.substr(j, chunk).c_str(), 16);
      write_mem(addr, data);
      addr += chunk / 2;
    }
  }
  mpz_clear(data);
  file.close();
  fprintf(stdout, "[loadmem] done\n");
}

void loadmem_t::read_mem(size_t addr, mpz_t &value) {
  // NB: mpz_t variables may not export <size> <uint32_t> beats, if initialized
  // with an array of zeros.
  simif.write(mmio_addrs.R_ADDRESS_H, addr >> 32);
  simif.write(mmio_addrs.R_ADDRESS_L, addr & ((1ULL << 32) - 1));
  uint32_t data[mem_data_chunk];
  for (size_t i = 0; i < mem_data_chunk; i++) {
    data[i] = simif.read(mmio_addrs.R_DATA);
  }
  mpz_import(value, mem_data_chunk, -1, sizeof(uint32_t), 0, 0, data);
}

void loadmem_t::write_mem(size_t addr, mpz_t &value) {
  simif.write(mmio_addrs.W_ADDRESS_H, addr >> 32);
  simif.write(mmio_addrs.W_ADDRESS_L, addr & ((1ULL << 32) - 1));
  simif.write(mmio_addrs.W_LENGTH, 1);
  size_t size;
  uint32_t *data =
      (uint32_t *)mpz_export(nullptr, &size, -1, sizeof(uint32_t), 0, 0, value);
  for (size_t i = 0; i < mem_data_chunk; i++) {
    simif.write(mmio_addrs.W_DATA, i < size ? data[i] : 0);
  }
}

static size_t ceil_div(size_t a, size_t b) { return ((a)-1) / (b) + 1; }

void loadmem_t::write_mem_chunk(size_t addr, mpz_t &value, size_t bytes) {
  const unsigned mem_data_chunk_bytes = mem_data_chunk * sizeof(uint32_t);

  simif.write(mmio_addrs.W_ADDRESS_H, addr >> 32);
  simif.write(mmio_addrs.W_ADDRESS_L, addr & ((1ULL << 32) - 1));

  size_t num_beats = ceil_div(bytes, mem_data_chunk_bytes);
  simif.write(mmio_addrs.W_LENGTH, num_beats);
  size_t size;
  uint32_t *data =
      (uint32_t *)mpz_export(nullptr, &size, -1, sizeof(uint32_t), 0, 0, value);
  for (size_t i = 0; i < num_beats * mem_data_chunk; i++) {
    simif.write(mmio_addrs.W_DATA, i < size ? data[i] : 0);
  }
}

void loadmem_t::zero_out_dram() {
  simif.write(mmio_addrs.ZERO_OUT_DRAM, 1);
  while (!simif.read(mmio_addrs.ZERO_FINISHED))
    ;
  dram_zeroed = true;
}

// [ZERORANGE 2026-11-10] see loadmem.h. Same register sequence as write_mem_chunk() (one W_ADDRESS_H/L +
// W_LENGTH per 4 KiB chunk, then the chunk's 32-bit words through W_DATA), with every word 0.
bool loadmem_t::zero_mem_range(uint64_t paddr, uint64_t len) {
  const uint64_t kChunk = 4096, kMax = 256ULL << 20;
  const size_t beat_bytes = (size_t)mem_data_chunk * sizeof(uint32_t);
  const uint64_t host_bytes = (mem_conf.addr_bits >= 64) ? ~0ULL : (1ULL << mem_conf.addr_bits);
  const char *why = nullptr;
  if (paddr < DRAM_BASE)                     why = "base below the DRAM base 0x80000000";
  else if (len == 0)                         why = "length 0";
  else if (len > kMax)                       why = "length above 256 MiB (use +zero-out-dram)";
  else if (paddr % kChunk || len % kChunk)   why = "base or length not a multiple of 4 KiB";
  else if (kChunk % beat_bytes)              why = "4 KiB is not a multiple of the LoadMem beat";
  else if (paddr - DRAM_BASE > host_bytes || len > host_bytes - (paddr - DRAM_BASE))
                                             why = "range beyond the LoadMem address space";
  if (why) {
    fprintf(stderr, "[zero-out-range] REFUSED base=0x%" PRIx64 " len=0x%" PRIx64 ": %s\n", paddr, len, why);
    return false;
  }
  const uint64_t off0 = paddr - DRAM_BASE;
  const size_t beats = kChunk / beat_bytes, words = kChunk / sizeof(uint32_t);
  const auto t0 = std::chrono::steady_clock::now();
  for (uint64_t off = off0; off < off0 + len; off += kChunk) {
    simif.write(mmio_addrs.W_ADDRESS_H, off >> 32);
    simif.write(mmio_addrs.W_ADDRESS_L, off & ((1ULL << 32) - 1));
    simif.write(mmio_addrs.W_LENGTH, beats);
    for (size_t i = 0; i < words; i++)
      simif.write(mmio_addrs.W_DATA, 0);
  }
  // Read back the first and the last beat of the range (the read path is not ordered behind the writer:
  // a non-zero last beat is read again, up to 3 times, before it counts as a failure).
  auto beat_zero = [&](uint64_t off) {
    mpz_t rb;
    mpz_init(rb);
    read_mem(off, rb);
    const bool z = (mpz_sgn(rb) == 0);
    mpz_clear(rb);
    return z;
  };
  const uint64_t last = off0 + len - beat_bytes;
  bool ok = beat_zero(off0);
  bool ok_last = false;
  for (int i = 0; i < 4 && !ok_last; i++)
    ok_last = beat_zero(last);
  const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  fprintf(stderr,
          "[zero-out-range] %s base=0x%" PRIx64 " len=0x%" PRIx64 " (%" PRIu64 " KiB, %" PRIu64
          " W_DATA words) in %.3f s; read-back first/last beat %s/%s\n",
          (ok && ok_last) ? "done" : "FAILED", paddr, len, len >> 10, len / sizeof(uint32_t), s,
          ok ? "0" : "NONZERO", ok_last ? "0" : "NONZERO");
  return ok && ok_last;
}

void loadmem_t::dump_trap_regs(uint64_t mscratch) {
  // OpenSBI _trap_handler saves the trap context on the M-stack derived from
  // mscratch. Verified against the checkpoint firmware disassembly:
  //   sp = mscratch - 280
  //   struct sbi_trap_regs at sp+0 .. sp+248: 32 xregs in the order
  //     zero,ra,sp,gp,tp,t0,t1,t2,s0,s1,a0..a7,s2..s11,t3..t6
  //   mepc    @ sp+256
  //   mstatus @ sp+264   (mstatusH @ sp+272)
  // Read purely through the LoadMem DMA path (read_mem) -- no halt()/resume().
  const uint64_t sp = mscratch - 280;
  const size_t beat_bytes = (size_t)mem_data_chunk * sizeof(uint32_t);
  const uint64_t region_lo = sp & ~((uint64_t)beat_bytes - 1);
  const uint64_t last_byte = sp + 279; // through mstatusH
  const size_t nbeats =
      (size_t)(((last_byte & ~((uint64_t)beat_bytes - 1)) - region_lo) /
               beat_bytes) +
      1;

  std::vector<uint8_t> mem(nbeats * beat_bytes, 0);
  for (size_t b = 0; b < nbeats; b++) {
    mpz_t rb;
    mpz_init(rb);
    read_mem((region_lo - DRAM_BASE) + b * beat_bytes, rb);
    size_t nw = 0;
    uint32_t *rw =
        (uint32_t *)mpz_export(nullptr, &nw, -1, sizeof(uint32_t), 0, 0, rb);
    for (size_t w = 0; w < beat_bytes / 4; w++) {
      uint32_t v = (rw && w < nw) ? rw[w] : 0;
      for (int k = 0; k < 4; k++)
        mem[b * beat_bytes + w * 4 + k] = (uint8_t)((v >> (8 * k)) & 0xff);
    }
    mpz_clear(rb);
  }

  auto dw = [&](uint64_t vaddr) -> uint64_t {
    size_t idx = (size_t)(vaddr - region_lo);
    uint64_t x = 0;
    for (int k = 0; k < 8; k++)
      x |= (uint64_t)mem[idx + k] << (8 * k);
    return x;
  };

  static const char *names[32] = {
      "zero", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2", "s0", "s1", "a0",
      "a1",   "a2", "a3",  "a4",  "a5", "a6", "a7", "s2", "s3", "s4", "s5",
      "s6",   "s7", "s8",  "s9",  "s10","s11","t3", "t4", "t5", "t6"};
  const uint64_t mepc = dw(sp + 256);
  const uint64_t mstatus = dw(sp + 264);

  fprintf(stdout,
          "[mstack] mscratch=0x%016" PRIx64 " sp=0x%016" PRIx64
          " (%zu beats x %zu B)\n",
          mscratch, sp, nbeats, beat_bytes);
  fprintf(stdout, "[mstack] mepc    = 0x%016" PRIx64 "\n", mepc);
  fprintf(stdout,
          "[mstack] mstatus = 0x%016" PRIx64 "  MPP=%" PRIu64
          " (0=U,1=S,3=M)\n",
          mstatus, (mstatus >> 11) & 3);
  for (int i = 0; i < 32; i++)
    fprintf(stdout, "[mstack]   x%-2d %-4s = 0x%016" PRIx64 "\n", i, names[i],
            dw(sp + i * 8));
  fflush(stdout);
}
