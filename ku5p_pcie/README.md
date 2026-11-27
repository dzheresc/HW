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
The results below are from Vivado 2017.4 on oldgamer. Use 2024.2 (UltraScale+ devices installed) for new
builds; a 2024.2 rebuild is recorded at the end of this file.

    vivado -mode batch -source gen_ip.tcl      # once
    vivado -mode batch -source build.tcl       # -> build/top.bit, build/top.bin

## Board facts (vendor docs: C:\Users\denis\Downloads\XCKU5P-FFVB676-slim)
"XCKU5P PCIe" board, XCKU5P-1FFVB676 (project part xcku5p-ffvb676-1-e), 6 user LEDs,
MT25QU128ABA1ESE QSPI flash (128 Mbit, 1.8 V, x4), Gen3 x8 edge connector, QSFP28, DDR4, RJ45, FMC.
- Factory image: Xilinx XDMA demo, 10ee:9038, class 0x0700, Gen3 x8, BAR0 64 KB, no Linux driver bound.
- PCIe: PCIE40E4_X0Y0, lanes GTY X0Y11 (lane 0) down to X0Y4 (lane 7), quads 226-225,
  refclk MGTREFCLK0_226 P7/P6, PERST# K9 (LVCMOS33, net PCIe_RST).
- LEDs LED2..LED7 = J11 H12 J12 J13 J14 J15 (LVCMOS33). In this design: led[0] heartbeat,
  [1] PERST# high, [2] link up, [3] SPI busy.
- Flash: 16 MB, so 3-byte addressing; fpgaflash polls Micron's flag status register.

## Bring-up once the KU5P's JTAG cable is on USB
1. Volatile load (factory flash untouched):
       ssh shed 'echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove'
       vivado -mode batch -source program.tcl -tclargs localhost:3121   # on oldgamer; that hw_server sees both cables
       ssh shed 'echo 1 | sudo tee /sys/bus/pci/rescan'
   If the link does not come up: `program.tcl localhost:3121 noprog status` reads LINK over JTAG-AXI.
2. `sudo ./fpgaflash -b ku5p info`, then back up the factory image first:
   `sudo ./fpgaflash -b ku5p read ku5p_flash_backup.bin`.
3. `sudo ./fpgaflash -b ku5p write build/top.bin`, then reboot/power-cycle to boot from flash.
   From then on, new images go over PCIe with no JTAG (remove + rescan after a reboot isn't needed).

## Status (2026-11-20)
- Working on hardware with build_v5 (in flash since 2026-11-20): Gen1 x8 link (Gen3 EQ does not complete,
  fine for flashing), BAR0 access, full flash read 11.6 s, write+verify of 4 MB in 23 s.
- Lessons: (1) the lanes run DOWNWARD over quads 226-225 (lane 0 = X0Y11, pin F2); the vendor's IP says
  quad 225 but their port pins override it, so top.xdc pins every lane. (2) After a JTAG load the CPU's
  PEG root port (00:01.0) trains the link but memory requests never arrive; a warm reboot with the design
  loaded (BIOS enumerates it) fixes that. (3) coreclk_freq must be forced to 250 after the quad/width set.
- Factory MicroBlaze image backed up twice (identical) before the first write:
  C:\develop\ku5p_flash_backup_2026-11-20.bin and oldgamer ~/ku5p_factory_a.bin / _b.bin,
  sha256 bf4dbda52228b06836dee5c119f5837bf5c9033a4a0826673987442c47d7dfcb (sync word at 0x50, data to 0xEB75DC).
  Restore with `sudo bin/fpgaflash -b ku5p write ~/ku5p_factory_a.bin`.
- LINK register (0x018) debug bits: [16] PHY ready, [17] PERST# released, [18] user_reset, [29:24] max LTSSM.
  0x024 debug: [31:24] CQ beats, [23:16] CC beats, [15:8] register accesses, [7:4] cq_tvalid/tready/cc_tvalid/tready.
- hw_servers on oldgamer: K7 cable :3121 (USB port 3-4), KU5P cable :3122 (USB port 2-1.8); use the
  port-path systemd-run script, the /dev/bus/usb numbers change on every boot.
- Later on 2026-11-20 (VERSION 0x00020001): REBOOT register at 0x0FC; `fpgaflash -b ku5p reboot` reloads the
  FPGA in 0.5 s and the BAR works straight after. Booted cold from flash it links at Gen3 x8; the Gen1 link
  above came from loading over JTAG. `sim/tb_reboot.v` tests `rtl/fpga_reboot.v`.


Vivado 2024.2 rebuild, 2026-11-27 (agentic VM, `timed_build.sh`, one NUMA node, nothing loaded or flashed): gen_ip 1 min 52 s, build 12 min 44 s (default, not dual). WNS +0.610 ns, WHS +0.011 ns, 0 critical warnings.
