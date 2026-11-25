# k7_host_ram: host RAM as FPGA memory over PCIe Gen2 x4 (xc7k325t board)

For the DRAM-less K7 board: random reads and writes of 128-byte lines in up to 1 GB of host hugepages
(512 x 2 MB), through the host's PCIe root port. **Built and simulated, never run on hardware.**

- `rtl/hr_core.v`  command/data port on one side, pcie_7x 64-bit AXI-ST TLPs on the other
  - 32 reads in flight, completions in any order and split, data returned in command order
  - a read sees every earlier write from this port (PCIe reads do not pass posted writes)
  - page table in hardware; lines outside `npages`, or any access with bus mastering off, are refused
    (writes swallowed, reads return zero with `rd_err`). oldgamer has no IOMMU, so this is the only guard
  - error or poisoned completions set `rd_err`; a lost completion (134 ms) sets `fatal`: all reads in
    flight fail and the port stays inert until reset. Do not reset with reads in flight
  - `rx_valid` must be qualified with the endpoint's RX ready (pcie_pio stalls RX while answering MMIO)
- `sim/run.sh`     Verilator: 8 seeds x 5 modes (random mix, flat-out reads, flat-out writes, bad
  completions, lost completion); prints PASS lines

Other files: `rtl/hr_test.v` (registers at BAR0 0x100, traffic generator/checker, latency counters), `rtl/top.v` (k7_cap
without 10G and capture; VERSION 0x00060000), `host/hrtool.cpp` (`status`, `test [PAGES]`; root, no IOMMU; refuses any
other VERSION; never `kill -9` it mid-test: the FPGA could still write to freed pages).

The read window defaults to 16: each 128 B read can return as two completions, and the endpoint's completion buffer is
believed to hold about 36 headers (PG054, not confirmed). Raise it only with that checked.

## Build (oldgamer, Vivado 2017.4) and load
    vivado -mode batch -source build.tcl
    g++ -O2 -std=c++17 -o hrtool host/hrtool.cpp
Loading replaces the running image (volatile). `sudo ~/ku5p_pcie/bin/fpgaflash -b k7 reboot` returns to the flash image.

Results (2026-11-25): sim/run.sh 41 of 41 pass; 6.40 B/cycle each way in the core simulation (1.6 GB/s at 250 MHz before
link overhead). Build: WNS +0.218 ns, WHS +0.036 ns, 5.2k LUTs, 9 BRAM. No hardware result yet.
