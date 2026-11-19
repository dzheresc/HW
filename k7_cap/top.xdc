## k7_cap: PCIe Gen2 x4 + 10GBASE-R on both SFP cages + packet capture on SFP A

## Board clock / LEDs
set_property PACKAGE_PIN F17 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]
set_property PACKAGE_PIN A19 [get_ports {led[0]}]
set_property PACKAGE_PIN B20 [get_ports {led[1]}]
set_property PACKAGE_PIN A20 [get_ports {led[2]}]
set_property PACKAGE_PIN A17 [get_ports {led[3]}]
set_property PACKAGE_PIN B17 [get_ports {led[4]}]
set_property PACKAGE_PIN A18 [get_ports {led[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]

## PCIe (quad 115)
set_property PACKAGE_PIN E17 [get_ports pcie_perst_n]
set_property IOSTANDARD LVCMOS33 [get_ports pcie_perst_n]
set_property PULLUP true [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]
set_property PACKAGE_PIN H6 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN H5 [get_ports pcie_refclk_n]
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]
# The PCIe IP's own XDC puts lanes 0..3 on X0Y7..X0Y4 (the SFP quad on this board);
# the board routes them to quad 115: lane 0 X0Y3 (J4) ... lane 3 X0Y0 (R4).
set_property LOC GTXE2_CHANNEL_X0Y3 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL && NAME =~ pcie/*pipe_lane?0?.gt_wrapper*}]
set_property LOC GTXE2_CHANNEL_X0Y2 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL && NAME =~ pcie/*pipe_lane?1?.gt_wrapper*}]
set_property LOC GTXE2_CHANNEL_X0Y1 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL && NAME =~ pcie/*pipe_lane?2?.gt_wrapper*}]
set_property LOC GTXE2_CHANNEL_X0Y0 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL && NAME =~ pcie/*pipe_lane?3?.gt_wrapper*}]
set_property PACKAGE_PIN J4 [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN L4 [get_ports {pci_exp_rxp[1]}]
set_property PACKAGE_PIN N4 [get_ports {pci_exp_rxp[2]}]
set_property PACKAGE_PIN R4 [get_ports {pci_exp_rxp[3]}]

## SFP+ cages (quad 116, QPLL from the 156.25 MHz refclk on F6/F5)
set_property PACKAGE_PIN F6 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN F5 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

set_property PACKAGE_PIN B6 [get_ports sfp_a_rx_p]
set_property PACKAGE_PIN B5 [get_ports sfp_a_rx_n]
set_property PACKAGE_PIN A4 [get_ports sfp_a_tx_p]
set_property PACKAGE_PIN A3 [get_ports sfp_a_tx_n]
set_property PACKAGE_PIN D14 [get_ports sfp_a_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_a_tx_disable]
set_false_path -to [get_ports sfp_a_tx_disable]

set_property PACKAGE_PIN C4 [get_ports sfp_b_rx_p]
set_property PACKAGE_PIN C3 [get_ports sfp_b_rx_n]
set_property PACKAGE_PIN B2 [get_ports sfp_b_tx_p]
set_property PACKAGE_PIN B1 [get_ports sfp_b_tx_n]
set_property PACKAGE_PIN C14 [get_ports sfp_b_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_b_tx_disable]
set_false_path -to [get_ports sfp_b_tx_disable]

## Config flash (dual-purpose bank 14 pins; CCLK via STARTUPE2)
set_property PACKAGE_PIN C23 [get_ports flash_cs_n]
set_property PACKAGE_PIN B24 [get_ports {flash_dq[0]}]
set_property PACKAGE_PIN A25 [get_ports {flash_dq[1]}]
set_property PACKAGE_PIN B22 [get_ports {flash_dq[2]}]
set_property PACKAGE_PIN A22 [get_ports {flash_dq[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {flash_cs_n flash_dq[*]}]
set_property PULLUP true [get_ports {flash_dq[*]}]
# The flash interface runs at <= 16 MHz with whole user_clk cycles of margin.
set_false_path -to [get_ports {flash_cs_n flash_dq[*]}]
set_false_path -from [get_ports {flash_dq[*]}]

## Async clock domains: sys clk, PCIe refclk (and its generated user clocks), SFP refclk
## (TX PCS clocks), and one recovered RX clock per cage. Crossings use synchronisers,
## Gray-coded counters, or a toggle handshake (eth10g.v, top.v).
set_clock_groups -asynchronous \
  -group [get_clocks sys_clk] \
  -group [get_clocks -include_generated_clocks {pcie_refclk txoutclk_x0y0}] \
  -group [get_clocks -include_generated_clocks sfp_refclk] \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins -hier -filter {NAME =~ *gt0_gtx10g_i*gtxe2_i/RXOUTCLK}]] \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins -hier -filter {NAME =~ *gt1_gtx10g_i*gtxe2_i/RXOUTCLK}]]

## Configuration
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
