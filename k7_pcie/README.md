# k7_pcie: PCIe Gen2 x1 endpoint + config-flash programmer (xc7k325t board)

- `rtl/top.v`        pcie_7x (x1, 5 GT/s, 64-bit/125 MHz, 10ee:7021, BAR0 4 KB) + JTAG-to-AXI + STARTUPE2
- `rtl/pcie_pio.v`   1-DW MMIO target (MRd/MWr 3DW; other read lengths get UR)
- `rtl/spi_regs.v`   register map and buffered SPI master (1 KB TX/RX, mode 0, ~15.6 MHz)
- `host/k7flash.cpp` Linux tool (sysfs resource0 mmap, needs root)
- `gen_ip.tcl` (once), `build.tcl`, `program.tcl` (JTAG load + `jtag_flash.tcl` helpers), `readback.tcl` (Vivado flash readback; replaces the design)

Flash: Spansion S25FL256S, JEDEC 01 02 19, 32 MB, 4-byte opcodes 0x13/0x12/0xDC/0x21.
Original contents: C:\develop\k7_flash_backup_2026-11-18.bin
(sha256 51f94a59d956c5a04664976864a709cab289032724e70896c6fa40633b182da8; matches Vivado JTAG readback).

Load + enumerate (no reboot):
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove'
    vivado -mode batch -source program.tcl -tclargs 192.168.0.215:3121
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/rescan'

Tool (on shed: ~/k7_pcie): `sudo ./k7flash info|status`, `read FILE [OFF [LEN]]`,
`verify FILE [OFF]`, `erase OFF LEN` (rounded out to 64 KB sectors), `write FILE [OFF]` (erase+program+verify).
Full read ~34 s.
