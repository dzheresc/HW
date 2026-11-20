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

## DDR4: two MT40A512M16HA-075E (x16) = 32-bit, banks 65/66 (vendor Demo/KU5P_DDR4_TEST/IO_KU5P.xdc).
## The MIG IP sets the I/O standards; only the pins are given here.
# 100 MHz DDR system clock (MIG creates the clock; DIFF_SSTL12 from the IP)
set_property PACKAGE_PIN H23 [get_ports c0_sys_clk_p]
set_property PACKAGE_PIN H24 [get_ports c0_sys_clk_n]
set_property PACKAGE_PIN L22 [get_ports {c0_ddr4_bg[0]}]
set_property PACKAGE_PIN E26 [get_ports {c0_ddr4_odt[0]}]
set_property PACKAGE_PIN D25 [get_ports {c0_ddr4_adr[0]}]
set_property PACKAGE_PIN J23 [get_ports {c0_ddr4_adr[1]}]
set_property PACKAGE_PIN C26 [get_ports {c0_ddr4_adr[2]}]
set_property PACKAGE_PIN J26 [get_ports {c0_ddr4_adr[3]}]
set_property PACKAGE_PIN E25 [get_ports {c0_ddr4_adr[4]}]
set_property PACKAGE_PIN G26 [get_ports {c0_ddr4_adr[5]}]
set_property PACKAGE_PIN K23 [get_ports {c0_ddr4_adr[6]}]
set_property PACKAGE_PIN D24 [get_ports {c0_ddr4_adr[7]}]
set_property PACKAGE_PIN K26 [get_ports {c0_ddr4_adr[8]}]
set_property PACKAGE_PIN F24 [get_ports {c0_ddr4_adr[9]}]
set_property PACKAGE_PIN D26 [get_ports {c0_ddr4_adr[10]}]
set_property PACKAGE_PIN J24 [get_ports {c0_ddr4_adr[11]}]
set_property PACKAGE_PIN H26 [get_ports {c0_ddr4_adr[12]}]
set_property PACKAGE_PIN B25 [get_ports {c0_ddr4_adr[13]}]
set_property PACKAGE_PIN M25 [get_ports {c0_ddr4_adr[14]}]
set_property PACKAGE_PIN F23 [get_ports {c0_ddr4_adr[15]}]
set_property PACKAGE_PIN H22 [get_ports {c0_ddr4_adr[16]}]
set_property PACKAGE_PIN N23 [get_ports {c0_ddr4_dqs_t[3]}]
set_property PACKAGE_PIN P23 [get_ports {c0_ddr4_dqs_c[3]}]
set_property PACKAGE_PIN U26 [get_ports {c0_ddr4_dqs_t[2]}]
set_property PACKAGE_PIN V26 [get_ports {c0_ddr4_dqs_c[2]}]
set_property PACKAGE_PIN W25 [get_ports {c0_ddr4_dqs_t[1]}]
set_property PACKAGE_PIN W26 [get_ports {c0_ddr4_dqs_c[1]}]
set_property PACKAGE_PIN V21 [get_ports {c0_ddr4_dqs_t[0]}]
set_property PACKAGE_PIN V22 [get_ports {c0_ddr4_dqs_c[0]}]
set_property PACKAGE_PIN W19 [get_ports {c0_ddr4_dq[0]}]
set_property PACKAGE_PIN T20 [get_ports {c0_ddr4_dq[1]}]
set_property PACKAGE_PIN U20 [get_ports {c0_ddr4_dq[2]}]
set_property PACKAGE_PIN U22 [get_ports {c0_ddr4_dq[3]}]
set_property PACKAGE_PIN W20 [get_ports {c0_ddr4_dq[4]}]
set_property PACKAGE_PIN T23 [get_ports {c0_ddr4_dq[5]}]
set_property PACKAGE_PIN U21 [get_ports {c0_ddr4_dq[6]}]
set_property PACKAGE_PIN T22 [get_ports {c0_ddr4_dq[7]}]
set_property PACKAGE_PIN Y25 [get_ports {c0_ddr4_dq[8]}]
set_property PACKAGE_PIN V24 [get_ports {c0_ddr4_dq[9]}]
set_property PACKAGE_PIN AA25 [get_ports {c0_ddr4_dq[10]}]
set_property PACKAGE_PIN W23 [get_ports {c0_ddr4_dq[11]}]
set_property PACKAGE_PIN AA24 [get_ports {c0_ddr4_dq[12]}]
set_property PACKAGE_PIN V23 [get_ports {c0_ddr4_dq[13]}]
set_property PACKAGE_PIN Y26 [get_ports {c0_ddr4_dq[14]}]
set_property PACKAGE_PIN W24 [get_ports {c0_ddr4_dq[15]}]
set_property PACKAGE_PIN T25 [get_ports {c0_ddr4_dq[16]}]
set_property PACKAGE_PIN N24 [get_ports {c0_ddr4_dq[17]}]
set_property PACKAGE_PIN P24 [get_ports {c0_ddr4_dq[18]}]
set_property PACKAGE_PIN P26 [get_ports {c0_ddr4_dq[19]}]
set_property PACKAGE_PIN U25 [get_ports {c0_ddr4_dq[20]}]
set_property PACKAGE_PIN P25 [get_ports {c0_ddr4_dq[21]}]
set_property PACKAGE_PIN R26 [get_ports {c0_ddr4_dq[22]}]
set_property PACKAGE_PIN R25 [get_ports {c0_ddr4_dq[23]}]
set_property PACKAGE_PIN P20 [get_ports {c0_ddr4_dq[24]}]
set_property PACKAGE_PIN N19 [get_ports {c0_ddr4_dq[25]}]
set_property PACKAGE_PIN P21 [get_ports {c0_ddr4_dq[26]}]
set_property PACKAGE_PIN N21 [get_ports {c0_ddr4_dq[27]}]
set_property PACKAGE_PIN R21 [get_ports {c0_ddr4_dq[28]}]
set_property PACKAGE_PIN P19 [get_ports {c0_ddr4_dq[29]}]
set_property PACKAGE_PIN R20 [get_ports {c0_ddr4_dq[30]}]
set_property PACKAGE_PIN N22 [get_ports {c0_ddr4_dq[31]}]
set_property PACKAGE_PIN J25 [get_ports {c0_ddr4_cs_n[0]}]
set_property PACKAGE_PIN G24 [get_ports {c0_ddr4_ck_t[0]}]
set_property PACKAGE_PIN G25 [get_ports {c0_ddr4_ck_c[0]}]
set_property PACKAGE_PIN K22 [get_ports {c0_ddr4_cke[0]}]
set_property PACKAGE_PIN K25 [get_ports c0_ddr4_reset_n]
set_property PACKAGE_PIN F25 [get_ports c0_ddr4_act_n]
set_property PACKAGE_PIN L23 [get_ports {c0_ddr4_ba[0]}]
set_property PACKAGE_PIN F22 [get_ports {c0_ddr4_ba[1]}]
set_property PACKAGE_PIN U19 [get_ports {c0_ddr4_dm_dbi_n[0]}]
set_property PACKAGE_PIN Y22 [get_ports {c0_ddr4_dm_dbi_n[1]}]
set_property PACKAGE_PIN T24 [get_ports {c0_ddr4_dm_dbi_n[2]}]
set_property PACKAGE_PIN R22 [get_ports {c0_ddr4_dm_dbi_n[3]}]

## user_clk <-> ui_clk crossings (besides the XPM FIFOs, which carry their own constraints):
## quasi-static configuration and result registers, and first synchronizer stages.
set_false_path -from [get_cells -hier -filter {NAME =~ *xcfg_*}]
set_false_path -from [get_cells -hier -filter {NAME =~ *xst_*}]
set_false_path -to   [get_cells -hier -filter {NAME =~ *xs0_*}]
