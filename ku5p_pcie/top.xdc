## XCKU5P-FFVB676 PCIe board (xcku5p-1ffvb676) -- PCIe flash programmer
## Pins from the vendor demo (Demo/XCKU5P_PCIe_DDR4_ETH/IO_KU5P.xdc) and schematic.

## PCIe
# PERST# from the edge connector (schematic net PCIe_RST, bank 84, 3.3 V)
set_property -dict {PACKAGE_PIN K9 IOSTANDARD LVCMOS33} [get_ports pcie_perst_n]
set_property PULLUP true [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]

# 100 MHz edge-connector refclk on MGTREFCLK0_226 (P7/P6).
set_property PACKAGE_PIN P7 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN P6 [get_ports pcie_refclk_n]
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# Lanes run DOWNWARD over quads 226-225 (vendor IO_KU5P.xdc pins; their IP's
# select_quad says 225, but these pins override it):
#   lane 0 = RXP3_226 F2 / TXP3_226 G5 = X0Y11 ... lane 7 = RXP0_225 Y2 / TXP0_225 AA5 = X0Y4
# Pin the ports exactly like the vendor XDC; these override the IP's own channel LOCs
# (each 4-lane channel container still lands whole in one quad).
set_property PACKAGE_PIN F2  [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN H2  [get_ports {pci_exp_rxp[1]}]
set_property PACKAGE_PIN K2  [get_ports {pci_exp_rxp[2]}]
set_property PACKAGE_PIN M2  [get_ports {pci_exp_rxp[3]}]
set_property PACKAGE_PIN P2  [get_ports {pci_exp_rxp[4]}]
set_property PACKAGE_PIN T2  [get_ports {pci_exp_rxp[5]}]
set_property PACKAGE_PIN V2  [get_ports {pci_exp_rxp[6]}]
set_property PACKAGE_PIN Y2  [get_ports {pci_exp_rxp[7]}]
set_property PACKAGE_PIN G5  [get_ports {pci_exp_txp[0]}]
set_property PACKAGE_PIN J5  [get_ports {pci_exp_txp[1]}]
set_property PACKAGE_PIN L5  [get_ports {pci_exp_txp[2]}]
set_property PACKAGE_PIN N5  [get_ports {pci_exp_txp[3]}]
set_property PACKAGE_PIN R5  [get_ports {pci_exp_txp[4]}]
set_property PACKAGE_PIN U5  [get_ports {pci_exp_txp[5]}]
set_property PACKAGE_PIN W5  [get_ports {pci_exp_txp[6]}]
set_property PACKAGE_PIN AA5 [get_ports {pci_exp_txp[7]}]

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

## Reboot (IPROG) logic runs on STARTUPE3 CFGMCLK (nominal 50 MHz, constrained with margin)
create_clock -period 16.000 -name cfgmclk [get_pins startup/CFGMCLK]
set_clock_groups -asynchronous -group [get_clocks cfgmclk] -group [get_clocks -include_generated_clocks pcie_refclk]
# The only crossing into cfgmclk is the sticky reboot request into a 3-flop synchronizer.
set_false_path -to [get_cells {reboot/req_s_reg[0]}]
