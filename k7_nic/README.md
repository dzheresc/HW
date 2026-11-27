# k7_nic: PCIe Gen2 x1 endpoint + 10GBASE-R on both SFP+ cages (xc7k325t board)

Merge of `k7_pcie` (PCIe endpoint 10ee:7021, BAR0 flash programmer) and `k7_10g_os`
(license-free 10GBASE-R: GT wizard + fabric gearbox + verilog-ethernet PCS) in one bitstream.

- `rtl/top.v`      pcie_7x (x1, 5 GT/s, 64-bit/125 MHz, BAR0 4 KB) + JTAG-to-AXI + STARTUPE2 + eth10g
- `rtl/eth10g.v`   the k7_10g_os top as a submodule (QPLL, GTX x2, gearboxes, PCS, status_vio)
- `rtl/pcie_pio.v`, `rtl/spi_regs.v`, `rtl/gearbox.v`, `rtl/verilog-ethernet/` as in the source designs
- `host/k7flash.cpp` (on shed: ~/k7_nic) — `status` also prints the 10G status on VERSION >= 2

GTX: PCIe lane 0 on GTXE2_CHANNEL_X0Y3 (quad 115, CPLL, 100 MHz refclk H6/H5);
SFP A / B on X0Y6 / X0Y7 (quad 116, shared QPLL, 156.25 MHz refclk F6/F5). No shared PLL or refclk.

LEDs: 0 heartbeat, 1 PCIe link up, 2 QPLL lock, 3 SFP A block lock, 4 SFP B block lock, 5 SPI busy.

BAR0 registers: as k7_pcie (ID 0x4B375043, VERSION now 0x00020000), plus
- 0x020 ETH_STAT: [0] QPLL lock [1] TX MMCM lock [3:2] TX FSM done B,A [5:4] RX FSM done B,A
  [7:6] TX reset done B,A [9:8] RX reset done B,A [11:10] RX MMCM lock B,A;
  [23:16] SFP A / [31:24] SFP B: [0] block lock [1] high BER [2] rx_status [7:3] PCS errors
- 0x024 TX PCS clock Hz, 0x028 SFP A RX PCS clock Hz,
  0x02C/0x030/0x034 SFP A idle / local-fault / remote-fault words per second, 0x038/0x03C/0x040 SFP B
  (rates update once a second)

Build and load (PowerShell, Vivado 2024.2):

    C:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source upgrade_ip.tcl     # once per checkout: 2017.4 .xci -> 2024.2
    C:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source build.tcl
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove'
    C:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source program.tcl -tclargs 192.168.0.215:3121
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/rescan'
    ssh shed 'cd k7_nic && sudo ./k7flash status && sudo ./k7flash info'

`program.tcl` prints the 10G status from the VIO; a third argument runs Tcl afterwards
(`jtag_flash.tcl` procs such as `status`, `jedec`; `read_status.tcl` procs `show_status`, `set_ctl`).

Verified 2026-11-18 (JTAG load, remove/rescan on oldgamer): 02:00.0 10ee:7021 LnkSta 5GT/s x1,
VERSION 0x00020000; flash JEDEC 01 02 19, full 32 MB read over PCIe in 34.4 s matches the backup
(sha256 51f94a59…); SFP A (switch) and SFP B (loopback) block-locked, ~156.25 M idle words/s,
zero faults and errors, also during the flash read; VIO and BAR0 status agree.
JTAG scripts pick the hw_server target that holds the xc7k325t (open_k7.tcl), so a second cable is fine.
Write path verified the same day (Denis ran it on oldgamer): program+verify of a random pattern at
0x1D0000-0x1FFFFF (192 KiB in 0.8 s), erase back to blank + verify, full 32 MB verify vs backup OK,
links still up and fault-free afterwards.


Vivado 2024.2 rebuild, 2026-11-27 (agentic VM, `timed_build.sh`, one NUMA node, nothing loaded or flashed): upgrade_ip 32 s (gtwizard 3.6, jtag_axi 1.2, pcie_7x 3.3, vio 3.0), build 16 min 33 s. WNS +0.990 ns, WHS +0.041 ns, 0 critical warnings.
