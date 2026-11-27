# Artix A7-35 LED Blinker

Simple FPGA project to flash an LED at 1Hz using Artix A7-35 board.

## Project Files

- **led_blinker.v** - Verilog module that divides the input clock to generate a 1Hz LED output
- **led_blinker.xdc** - Pin constraints file for clock, reset, and LED pins
- **create_project.tcl** - TCL script to create a Vivado 2024.2 project

## Usage

1. Open Vivado 2024.2
2. Run the TCL script: `source create_project.tcl`
3. Run synthesis, implementation, and generate bitstream
4. Program the FPGA with the generated bitstream

## Notes

- Default clock frequency: 100MHz
- LED blinks at 1Hz (toggles every 0.5 seconds)
- Pin assignments in XDC file are for typical Arty A7-35T board - adjust if using a different variant



Vivado 2024.2 rebuild, 2026-11-27 (agentic VM, `timed_build.sh`, one NUMA node, nothing loaded or flashed): `vivado -mode batch -source ../proj_build.tcl` 2 min 46 s. WNS +4.969 ns. 1 critical warning: led_blinker.xdc:23 names the net `rst_IBUF`, which does not exist.
