// See LICENSE for license details.

#include "loadmem.h"

#include <elf.h>
#include <fstream>
#include <cstring>

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
          mpz_import(mpz_buf, to_read, -1, 1, 0, 0, buf.data());
          write_mem_chunk(cur_offset, mpz_buf, to_read);
          cur_offset += to_read;
          remaining -= to_read;
        }
        mpz_clear(mpz_buf);
      }
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
}
