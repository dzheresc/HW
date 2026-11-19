# ku5p_pcie: PCIe endpoint + config-flash programmer (xcku5p board)

Port of `k7_pcie` to the second board in the shed PC (xcku5p, PCIe slot 01:00.0).
Same register map and host tool; the flash is reached through STARTUPE3.

- `rtl/top.v`          pcie4_uscale_plus (default Gen3 x8, 256-bit/250 MHz, 10ee:9021, BAR0 4 KB)
                       + JTAG-to-AXI + STARTUPE3. `DUAL_QSPI` adds the second flash of an x8 pair
                       (D04-D07/FCS2_B), `BOARD_LEDS` adds led[3:0].
- `rtl/pcie_cq_pio.v`  1-DW MMIO target on the US+ CQ/CC interfaces (64/128/256-bit);
                       other read lengths and non-posted types get UR.
- `rtl/spi_regs.v`     register map + buffered SPI master, parameterized (shared with K7: ID, VERSION,
                       FEAT, reset divider). New vs K7: CTRL[8] flash select, 0x020 FEAT.
- `sim/tb.v`           PIO + SPI + flash model; passes at DATA_W 64/128/256 (xsim).
- `host/fpgaflash.cpp` Linux tool for **both** boards (replaces k7flash): `list`, `-b k7|ku5p`,
                       `-d BDF`, `-c 0|1` for dual QSPI; Micron flag-status polling/error checks added.
- `gen_ip.tcl` (once), `build.tcl [dual] [leds]`, `program.tcl` (JTAG load, picks the target with an
  xcku5p), `jtag_flash.tcl` (JTAG-AXI register/SPI helpers).

## Tools
UltraScale+ device support exists only on oldgamer: `/opt/Xilinx/Vivado/2017.4` (the Dell's 2017.4
and 2024.2 have 7-series only). Build there:

    cd ~/ku5p_pcie && source /opt/Xilinx/Vivado/2017.4/settings64.sh
    vivado -mode batch -source gen_ip.tcl      # once
    vivado -mode batch -source build.tcl       # -> build/top.bit, build/top.bin

## Board facts (vendor docs: C:\Users\denis\Downloads\XCKU5P-FFVB676-slim)
"XCKU5P PCIe" board, XCKU5P-1FFVB676 (project part xcku5p-ffvb676-1-e), 6 user LEDs,
MT25QU128ABA1ESE QSPI flash (128 Mbit, 1.8 V, x4), Gen3 x8 edge connector, QSFP28, DDR4, RJ45, FMC.
- Factory image: Xilinx XDMA demo, 10ee:9038, class 0x0700, Gen3 x8, BAR0 64 KB, no Linux driver bound.
- PCIe: PCIE40E4_X0Y0, lanes GTY X0Y0..X0Y7 (quads 224-225, select_quad GTY_Quad_225),
  refclk MGTREFCLK0_226 P7/P6, PERST# K9 (LVCMOS33, net PCIe_RST).
- LEDs LED2..LED7 = J11 H12 J12 J13 J14 J15 (LVCMOS33). In this design: led[0] heartbeat,
  [1] PERST# high, [2] link up, [3] SPI busy.
- Flash: 16 MB, so 3-byte addressing; fpgaflash polls Micron's flag status register.

## Bring-up once the KU5P's JTAG cable is on USB
1. Volatile load (factory flash untouched):
       ssh shed 'echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove'
       vivado -mode batch -source program.tcl            # on oldgamer, localhost:3121
       ssh shed 'echo 1 | sudo tee /sys/bus/pci/rescan'
   If the link does not come up: `program.tcl localhost:3121 noprog status` reads LINK over JTAG-AXI.
2. `sudo ./fpgaflash -b ku5p info`, then back up the factory image first:
   `sudo ./fpgaflash -b ku5p read ku5p_flash_backup.bin`.
3. `sudo ./fpgaflash -b ku5p write build/top.bin`, then reboot/power-cycle to boot from flash.
   From then on, new images go over PCIe with no JTAG (remove + rescan after a reboot isn't needed).

## Status (2026-11-18)
- Built on oldgamer (2017.4): timing met (WNS +0.153 ns), no critical warnings; 2.4% LUTs.
  build/top.bin sha256 bfb05a878b989b55e52e3ff77d656aa8c0c2fb2738571378bafa0bbcce5873a2 (4.2 MB, compressed).
- fpgaflash built on oldgamer at ~/ku5p_pcie/bin/fpgaflash (`sudo ~/ku5p_pcie/bin/fpgaflash list` sees the K7).
- Not yet run on hardware: needs the KU5P's Platform Cable on USB for the first volatile load.
