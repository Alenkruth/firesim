#include "cpu_managed_stream.h"
#include "core/simif.h"

#include <cassert>
#include <cerrno>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/types.h>

using namespace CPUManagedStreams;

/**
 * @brief Enqueues as much as num_bytes of data into the associated stream
 *
 * @param src Source from which to copy data to enqueue
 * @param num_bytes Desired number of bytes to enqueue
 * @param required_bytes Minimum number of bytes to enqueue. If fewer bytes
 *        would be enqueued, this method enqueues none and returns 0.
 * @return size_t
 */
size_t CPUManagedStreams::CPUToFPGADriver::push(void *src,
                                                size_t num_bytes,
                                                size_t required_bytes) {

  assert(num_bytes >= required_bytes);

  // Similarly to above, the legacy implementation of DMA does not correctly
  // implement non-multiples of 512b. The FPGA-side queue will take on the
  // high-order bytes of the final beat in the transaction, and the strobe is
  // not respected. So put the assertion here and discuss what to do next.
  assert((num_bytes % fpga_buffer_width_bytes()) == 0);

  auto num_beats = num_bytes / fpga_buffer_width_bytes();
  auto threshold_beats = required_bytes / fpga_buffer_width_bytes();

  assert(threshold_beats <= fpga_buffer_size());
  auto space_available = fpga_buffer_size() - mmio_read(count_addr());

  if ((space_available == 0) || (space_available < threshold_beats)) {
    return 0;
  }

  auto push_beats = std::min(space_available, num_beats);
  auto push_bytes = push_beats * fpga_buffer_width_bytes();
  auto bytes_written =
      cpu_managed_axi4_write(dma_addr(), (char *)src, push_bytes);
  assert(bytes_written == push_bytes);

  return bytes_written;
}

/**
 * @brief Dequeues as much as num_bytes of data from the associated bridge
 * stream.
 *
 * @param dest  Buffer into which to copy dequeued stream data
 * @param num_bytes  Bytes of data to dequeue
 * @param required_bytes  Minimum number of bytes to dequeue. If fewer bytes
 * would be dequeued, dequeue none and return 0.
 * @return size_t Number of bytes successfully dequeued
 */
size_t CPUManagedStreams::FPGAToCPUDriver::pull(void *dest,
                                                size_t num_bytes,
                                                size_t required_bytes) {
  assert(num_bytes >= required_bytes);

  // The legacy code is clearly broken for requests that aren't a
  // multiple of 512b since CPU_MANAGED_AXI4_SIZE is fixed to the full width of
  // the AXI4 IF. The high-order bytes of the final word will be copied into the
  // destination buffer (potentially an overflow, bug 1), and since reads are
  // destructive, will not be visible to future pulls (bug 2). So i've put this
  // assertion here for now...

  // Due to the destructive nature of reads, if we wish to support reads that
  // aren't a multiple of 512b, we'll need to keep a little buffer around for
  // the remainder, and prepend this to the destination buffer.
  assert((num_bytes % fpga_buffer_width_bytes()) == 0);

  auto num_beats = num_bytes / fpga_buffer_width_bytes();
  auto threshold_beats = required_bytes / fpga_buffer_width_bytes();

  assert(threshold_beats <= fpga_buffer_size());
  auto count = mmio_read(count_addr());

  if ((count == 0) || (count < threshold_beats)) {
    return 0;
  }

  auto pull_beats = std::min(count, num_beats);
  auto pull_bytes = pull_beats * fpga_buffer_width_bytes();

  // [DRVXDMA] A destination that is not page-aligned lets the XDMA driver split the
  // read at a host page boundary that is not a beat multiple; the two halves then read
  // one more beat than the queue holds and the transfer never completes (FireSim
  // issue #208; see page_aligned_sized_array in core/bridge_driver.h).  Warn once so
  // a bridge with an unaligned buffer is named instead of showing up as a 10 s hang.
  constexpr uintptr_t kHostPageBytes = 4096;
  static bool warned_unaligned = false;
  if (!warned_unaligned && (reinterpret_cast<uintptr_t>(dest) & (kHostPageBytes - 1)) &&
      ((reinterpret_cast<uintptr_t>(dest) & (kHostPageBytes - 1)) + pull_bytes > kHostPageBytes)) {
    warned_unaligned = true;
    fprintf(stderr,
            "[CPUManagedStream] WARNING: pull from card addr 0x%" PRIx64 " into %p: the "
            "destination is not page-aligned and this %zu-byte read crosses a page; "
            "XDMA reads may hang (FireSim #208)\n",
            (uint64_t)dma_addr(), dest, (size_t)pull_bytes);
  }

  auto bytes_read = cpu_managed_axi4_read(dma_addr(), (char *)dest, pull_bytes);
  // [DRVXDMA] cpu_managed_axi4_read returns pread()'s ssize_t as size_t, so a failed
  // read (XDMA c2h timeout: -ETIMEDOUT/-EIO) arrived here as SIZE_MAX and was passed
  // up as a byte count; the IFT bridge then read past its buffer (SIGSEGV).  After a
  // failed read the FPGA queue has been partly dequeued and its AXI read is still
  // outstanding, so the stream can no longer be trusted: stop with a clear message
  // instead of crashing or blocking 10 s on every later pull.
  if (static_cast<ssize_t>(bytes_read) < 0) {
    const int err = errno;
    fprintf(stderr,
            "[CPUManagedStream] FATAL: DMA read of %zu bytes from card addr 0x%" PRIx64
            " failed: %s (errno %d). The stream is no longer framed; stopping the "
            "driver (exit 74).\n",
            (size_t)pull_bytes, (uint64_t)dma_addr(), strerror(err), err);
    fflush(stdout);
    exit(74);
  }
  // Short read: can occur when simulation ends mid-DMA transfer (FPGA resets while
  // host has a pull in flight). Return what we got rather than asserting.
  return bytes_read;
}

CPUManagedStreamWidget::CPUManagedStreamWidget(
    simif_t &simif,
    unsigned index,
    const std::vector<std::string> &args,
    std::vector<CPUManagedStreams::StreamParameters> &&from_cpu,
    std::vector<CPUManagedStreams::StreamParameters> &&to_cpu) {
  assert(index == 0 && "only one managed stream engine is allowed");

  auto &io = simif.get_cpu_managed_stream_io();
  for (auto &&params : from_cpu) {
    cpu_to_fpga_streams.push_back(
        std::make_unique<CPUManagedStreams::CPUToFPGADriver>(std::move(params),
                                                             io));
  }

  for (auto &&params : to_cpu) {
    fpga_to_cpu_streams.push_back(
        std::make_unique<CPUManagedStreams::FPGAToCPUDriver>(std::move(params),
                                                             io));
  }
}
