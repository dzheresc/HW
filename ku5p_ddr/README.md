# ku5p_ddr: DDR4 demo for the KU5P board (memory test + host DMA over PCIe)

Builds on `ku5p_pcie` (same PCIe endpoint 10ee:9021, ID "KUPC", BAR0 4 KB, config-flash SPI
master and the REBOOT register at 0x0FC, so `fpgaflash -b ku5p` keeps working and the card can
always be re-flashed over PCIe) and adds the board's 2 GB of DDR4.

## Memory on the board (vendor docs, `XCKU5P-FFVB676-slim`)
- Two Micron MT40A512M16HA-075E (8 Gb, x16) side by side: 32-bit bus, 2 GB, single rank,
  no ECC, data mask used (DM_NO_DBI). Banks 65/66 (HP, 1.2 V).
- 100 MHz differential DDR system clock on H23/H24. Pinout in `top.xdc` (from the vendor's
  `Demo/KU5P_DDR4_TEST/IO_KU5P.xdc`; DM pins renamed to the MIG's `c0_ddr4_dm_dbi_n`).
- The vendor's PCIe+DDR demo runs it at 2400 MT/s (tCK 833 ps, CL17/CWL12), their plain DDR test
  at 1250 MT/s. This design uses 2400 MT/s: ui_clk 300 MHz, 256-bit app data = one BL8 burst
  (32 bytes) per command, peak 9.6 GB/s. `gen_ip.tcl 1250` regenerates the MIG at 1600 MT/s
  (tCK 1250 ps) if 2400 does not calibrate.

## Design
- `rtl/top.v`          ku5p_pcie top + MIG (`ddr4_0`, native interface) + the blocks below.
- `rtl/ddr_bridge.v`   user_clk (250 MHz) <-> ui_clk (300 MHz) DDR port: async command FIFO and
                       read-data FIFO (XPM), reads only issued when the read FIFO has room.
                       Hands the MIG to the memory test while that runs.
- `rtl/ddr_memtest.v`  In-fabric write pass + read/verify pass straight on the MIG at full rate,
                       four patterns (address^seed, inverted, xorshift, seed/~seed alternating),
                       error count, first failing address/expected/read word, cycle counts.
- `rtl/ddr_dma.v`      One-transfer-at-a-time DMA on the PCIe requester interfaces (RQ/RC,
                       client tags): host->DDR with memory reads of min(MRRS, 512) bytes and up to
                       16 tags in flight (completions are placed by tag + byte count, so they may
                       arrive split and out of order); DDR->host with memory writes of
                       min(MPS, 256) bytes.
- `rtl/ddr_ctrl.v`     Registers 0xC00..0xCBC (map at the top of the file), single 32-byte
                       accesses, clock-domain crossings.
- `rtl/spi_regs.v`, `pcie_cq_pio.v`, `fpga_reboot.v` unchanged from ku5p_pcie.
- `sim/tb_ddr.sv`      Datapath test against a behavioral MIG (random ready, 20-40 cycle read
                       latency) and a host model (RCB splitting, interleaved completions):
                       `bash sim/run_ddr.sh` on oldgamer.
- `host/ku5pddr.cpp`   Linux tool: `status`, `memtest`, `dmatest` (random data over all 2 GB from
                       the host, read back, verify, bandwidth), `write`/`read` a file, `peek`/`poke`,
                       `recal`. DMA buffers are 2 MB hugepages (root, no IOMMU, like k7cap).

LEDs (silkscreen LED2..LED7): heartbeat, PERST# released, link up, SPI busy, DDR calibrated,
memory test found errors.

## Build (oldgamer, Vivado 2017.4 with UltraScale+)
    cd ~/ku5p_ddr && source /opt/Xilinx/Vivado/2017.4/settings64.sh
    vivado -mode batch -source gen_ip.tcl      # once (PCIe, MIG, JTAG-AXI)
    vivado -mode batch -source build.tcl       # -> build/top.bit, build/top.bin
    g++ -O2 -std=c++17 -o bin/ku5pddr host/ku5pddr.cpp

## Status (2026-11-20)
- build_v1 (oldgamer `~/ku5p_ddr/build`, copy in `build_v1/`): timing met (WNS +0.291 ns,
  WHS +0.010 ns), 17.9k LUTs / 25.9k FFs / 58 BRAM tiles, top.bin sha256 b507c55a...0ccc.
  No unsafe clock crossings in report_clock_interaction.
- Datapath simulation passes. **Not yet tried on hardware** (calibration at 2400 MT/s, DMA on the
  real root port).

## Load and run
Normal path (no JTAG): write the image with the ku5p_pcie tool, then warm-reboot the PC so the
BIOS enumerates the new design (the CPU root port 00:01.0 needs that, see ku5p_pcie):

    sudo ~/ku5p_pcie/bin/fpgaflash -b ku5p write build/top.bin
    sudo reboot

Then:

    sudo bin/ku5pddr status          # calibration, link, MPS/MRRS
    sudo bin/ku5pddr memtest         # all 2 GB, 4 patterns, in the FPGA
    sudo bin/ku5pddr dmatest         # all 2 GB from the host over PCIe
    sudo bin/ku5pddr peek 0x1000

If anything goes wrong the flash can be rewritten over PCIe as long as the link comes up (this
design keeps the SPI registers), and the factory image backup is at oldgamer `~/ku5p_factory_a.bin`.
