# k7_host_ram: host RAM as FPGA memory over PCIe Gen2 x4 (xc7k325t board)

For the DRAM-less K7 board: random reads and writes of 128-byte lines in up to 1 GB of host hugepages
(512 x 2 MB), through the host's PCIe root port. **In progress: core and simulation only, no top level,
no host tool, never run on hardware.**

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

Results (2026-11-25): 40 of 40 pass; 6.40 B/cycle each way in simulation (1.6 GB/s at 250 MHz before link
overhead). Core alone, out of context, Vivado 2017.4: meets 250 MHz, WNS +0.452 ns.

Plan: top level from `k7_cap` (pcie_x4, pcie_pio, spi_regs, fpga_reboot; 2017.4 IP, builds on oldgamer),
on-chip tester, host tool, then hardware. Loading it replaces the running image; `fpgaflash -b k7 reboot`
returns to whatever is in flash.
