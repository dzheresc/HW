# Hardware projects

FPGA designs and host tools, one self-contained folder per project: Verilog, XDC, Tcl scripts, Linux
host tools, simulation. To reuse one, copy its folder; nothing is shared between folders.

## Start here

| You need | Copy from |
|---|---|
| K7 board pins | `xdc/k7_325t_board_master.xdc` |
| 10GBASE-R without a licensed core | `k7_10g_os` (newest PCS copy: `k7_link/rtl/eth10g.v`, `gearbox.v`) |
| 10G MAC that replies to ARP, ping and UDP echo | `k7_link` |
| Send UDP from the FPGA | `k7_udp` |
| PCIe endpoint with BAR0 registers, flash over PCIe | `k7_pcie` (K7, Gen2 x1), `k7_cap` (K7, Gen2 x4), `ku5p_pcie` (KU5P) |
| DMA to host memory | `k7_cap` (K7), `ku5p_ddr` (KU5P) |
| DDR4 memory test | `ku5p_ddr` (PCIe), `ku5pf_ddr` (JTAG only) |
| Reload the FPGA from flash by a register write | `rtl/fpga_reboot.v` in `k7_cap`, `k7_link`, `ku5p_pcie` |
| Flash tool for the K7 and KU5P cards | `ku5p_pcie/host/fpgaflash.cpp` |

## Toolchain

- **Vivado 2024.2 for all new work.** 2017.4 is only named where an older project was last built with it.
  The K7 projects other than `k7_link` hold 2017.4 `.xci` files. To move one to 2024.2, run its IP through
  `upgrade_ip` first (see `k7_link/upgrade_ip.tcl`). KU5P projects need the UltraScale+ devices installed.
- Verilog for designs, SystemVerilog only in some testbenches. Host tools are C++ for Linux.
- Build outputs (bitstreams, checkpoints, reports, generated IP) are not committed.

Typical build, from a project folder (each README has the exact steps and the last result):

    vivado -mode batch -source gen_ip.tcl      # KU5P projects: once, creates the IP
    vivado -mode batch -source build.tcl       # build/top.bit (plus top.bin where the design boots from flash)
    vivado -mode batch -source program.tcl     # volatile JTAG load

K7 projects read the committed `.xci` files; their `gen_ip.tcl` is only for changing the IP.
`k7_blink` uses openXC7 in Docker instead (`build.ps1` / `build.sh`).

Scripts and READMEs contain addresses and paths of the original lab (`192.168.0.215`, also called `shed` or
`oldgamer`, is the PC holding the cards; `C:\develop\...` is the workstation). Pass your own `host:port` to
`program.tcl`.

## Boards

**K7 board**: `xc7k325tffg676-2` (speed grade not confirmed), PCIe Gen2 x4, two SFP+ cages, 32 MB QSPI.
- 100 MHz clock F17, LEDs A19 B20 A20 A17 B17 A18 (LVCMOS33)
- PCIe refclk H6/H5, PERST# E17, lane 0 = X0Y3 (J4) down to lane 3 = X0Y0 (R4). The lanes are reversed, so
  `top.xdc` has to override the IP placement
- SFP refclk 156.25 MHz F6/F5. SFP A = X0Y7 (RX B6/B5, TX A4/A3), SFP B = X0Y6
- Flash S25FL256S: FCS_B C23, D0..D3 B24 A25 B22 A22, clock through STARTUPE2

**KU5P x8 card**: `xcku5p-ffvb676-1-e`, 16 MB QSPI (MT25QU128, 1.8 V), PCIe Gen3 x8, 2 GB DDR4.
- PCIe refclk P7/P6, PERST# K9, lane 0 = X0Y11 (F2) down to lane 7 = X0Y4 (Y2)
- DDR clock 100 MHz H23/H24, LEDs J11 H12 J12 J13 J14 J15. DDR4 pins: `ku5p_ddr/top.xdc`

**RK-XCKU5P-F V1.2**: `xcku5p-ffvb676-2-i`, USB-C JTAG/UART, 2 GB DDR4.
- 200 MHz clock T24/U24 (the 50 MHz PL_CLK on AC13 did not toggle), LEDs H9 J9 G11 H11, UART TX/RX AC14/AD13

**Arty A7-35T**: `xc7a35ticsg324-1L`, 100 MHz clock E3.

## Projects

Kintex-7 xc7k325t:
- `k7_blink/` - LED blink with the open-source openXC7 flow (yosys + nextpnr)
- `k7_10g/` - 10GBASE-R link bring-up on SFP A with the Xilinx PCS/PMA core
- `k7_10g_os/` - 10G link using a raw GTX plus open-source PCS (verilog-ethernet)
- `k7_pcie/` - PCIe Gen2 x1 endpoint with BAR0 registers and QSPI flash access
- `k7_nic/` - PCIe plus 10G on both cages combined
- `k7_udp/` - 1 Hz UDP counter sender over 10G, controlled through BAR0
- `k7_cap/` - 10G packet capture: SFP A to a host hugepage ring by DMA over PCIe Gen2 x4, C++ pcap tool
- `k7_link/` - dual-port 10G test: replies to ARP, ping and UDP echo on both SFP+ ports (2024.2; simulated and
  built, not yet run on hardware)

Kintex UltraScale+ KU5P:
- `ku5p_pcie/` - x8 card: PCIe endpoint, flash programming and reload over PCIe, `fpgaflash` host tool
- `ku5p_ddr/` - x8 card: DDR4 memory test and host DMA over PCIe, C++ test tool (status in its README)
- `ku5pf_ddr/` - RK-XCKU5P-F: DDR4 test over JTAG

Arty A7-35T:
- `arty_blink/` - LED blinker with self-checking testbench and flash script (2024.2)

Related: Arty and RK-XCKU5P-F board bring-up (UART, DDR, Ethernet) is in the separate `squeeze` repository.

## Third-party code

The `rtl/verilog-ethernet/` folders come from the verilog-ethernet project (see `COPYING` there). Some files
are patched locally, as noted in the project READMEs.

## Legacy

Earlier projects, built with Vivado 2017.4 project-mode scripts (`create_project.tcl`).

- `blink/` - 1 Hz LED blinker for the Arty A7-35 (xc7a35t)
- `blink.up/` - LED blinker for the KU5P board (xcku5p-ffvb676-2-i), differential system clock, non-project build and JTAG program scripts
- `eth_recv/` - Arty A7-35: shows received MII Ethernet nibbles (`eth_rxd[3:0]`) live on the LEDs
- `udp/` - first UDP sender attempt: a single-module UDP/IP/Ethernet stack sending to 192.168.0.98:5555 over GMII
- `udp_2/` - second UDP sender for the Arty A7-35 over MII (on-board LAN8710A PHY), split into packet generator and MII TX modules
