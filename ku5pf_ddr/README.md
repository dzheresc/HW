# ku5pf_ddr: DDR4 test over JTAG on the RK-XCKU5P-F board

Board: RK-XCKU5P-F V1.2 ("fat" KU5P), `xcku5p-ffvb676-2-i`. This is not the x8 card used by
`ku5p_pcie` / `ku5p_ddr`. JTAG and UART share the on-board USB-C connector. No PCIe in this design.

- MIG DDR4, native interface, 2400 MT/s, 2 x MT40A512M16LY (x16) = 32-bit, 2 GB.
- `rtl/ddr_regs.v` behind a JTAG-to-AXI master: same 0xC00 register map as `ku5p_ddr`, without DMA.
- `rtl/ddr_memtest.v`, `rtl/ddr_bridge.v`: taken from `ku5p_ddr`.
- `ddr_jtag.tcl`: `status`, `ddr_wr`, `ddr_rd`, `burst_test`, `memtest`, `recal`.

## Pins and clocks
- DDR system clock: 200 MHz differential, T24/U24 (bank 65). DDR4 pins are in `top.xdc`.
- PL_CLK: 50 MHz oscillator net on AC13. **It did not toggle on the tested board**; use T24/U24.
  Here it only drives a heartbeat LED. The control and debug hub clock is STARTUPE3 CFGMCLK
  (about 50 MHz, +-15%).
- LED1..LED4 = H9 J9 G11 H11 (high = on), KEY1..KEY4 = K9 K10 J10 J11, UART TX/RX = AC14/AD13.

## Build and load (Vivado 2024.2 with UltraScale+ devices)

    vivado -mode batch -source gen_ip.tcl      # once
    vivado -mode batch -source build.tcl       # build/top.bit
    vivado -mode batch -source program.tcl -tclargs localhost:3121    # JTAG load, runs the demo

Volatile load only, no flash image is written. `gen_ip.tcl` picks the first memory part the MIG
catalog accepts, so check its `CHK` output.

## Status
Built 2026-11-21: WNS +0.464 ns, WHS +0.011 ns. The last load attempt of this design found no board
on JTAG, so this folder has no recorded hardware result. The same memory setup (MIG 2024.2,
MT40A512M16LY-075 at 2400 MT/s, same DDR pins) passed on this board in the `rk_xcku5p_f_ddr4` project
of the separate `squeeze` repository: 0 errors over 2 GB, 7.69 GB/s write, 8.91 GB/s read.


Vivado 2024.2 rebuild, 2026-11-27 (agentic VM, `timed_build.sh`, one NUMA node, nothing loaded or flashed): gen_ip 1 min 17 s, build 16 min 2 s. WNS +0.336 ns, WHS +0.013 ns, 0 critical warnings.
