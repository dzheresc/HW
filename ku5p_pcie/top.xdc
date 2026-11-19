## XCKU5P-FFVB676 PCIe board (xcku5p-1ffvb676) -- PCIe flash programmer
## Pins from the vendor demo (Demo/XCKU5P_PCIe_DDR4_ETH/IO_KU5P.xdc) and schematic.

## PCIe
# PERST# from the edge connector (schematic net PCIe_RST, bank 84, 3.3 V)
set_property -dict {PACKAGE_PIN K9 IOSTANDARD LVCMOS33} [get_ports pcie_perst_n]
set_property PULLUP true [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]

# 100 MHz edge-connector refclk on MGTREFCLK0_226 (P7/P6). The lanes use quads
# 224-225 (rx F2,H2,...,Y2 = GTYE4_CHANNEL_X0Y0..X0Y7), placed by the IP's XDC
# (select_quad GTY_Quad_225 in gen_ip.tcl), exactly as the vendor XDMA demo.
set_property PACKAGE_PIN P7 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN P6 [get_ports pcie_refclk_n]
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

## User LEDs (silkscreen LED2..LED7), bank 84
set_property -dict {PACKAGE_PIN J11 IOSTANDARD LVCMOS33} [get_ports -quiet {led[0]}]
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS33} [get_ports -quiet {led[1]}]
set_property -dict {PACKAGE_PIN J12 IOSTANDARD LVCMOS33} [get_ports -quiet {led[2]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports -quiet {led[3]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports -quiet {led[4]}]
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports -quiet {led[5]}]
set_false_path -to [get_ports -quiet {led[*]}]

## Config flash: MT25QU128ABA1ESE (128 Mbit, 1.8 V) on the dedicated bank-0
## pins, driven through STARTUPE3 (no LOCs). SPI clock <= 16 MHz, both ends
## registered: no timing needed.
set_false_path -through [get_pins {startup/DO[*]}]
set_false_path -through [get_pins startup/FCSBO]
set_false_path -through [get_pins startup/USRCCLKO]
set_false_path -through [get_pins {startup/DI[*]}]

## Second flash of a dual QSPI pair: this board has none; build.tcl dual adds dual_qspi.xdc.

## Configuration (vendor demo: SPIx4 at 51 MHz). 128 Mbit -> 3-byte addressing.
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
