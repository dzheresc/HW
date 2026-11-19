set_property PACKAGE_PIN F17 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk [get_ports clk]

set_property PACKAGE_PIN A19 [get_ports {led[0]}]
set_property PACKAGE_PIN B20 [get_ports {led[1]}]
set_property PACKAGE_PIN A20 [get_ports {led[2]}]
set_property PACKAGE_PIN A17 [get_ports {led[3]}]
set_property PACKAGE_PIN B17 [get_ports {led[4]}]
set_property PACKAGE_PIN A18 [get_ports {led[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]

set_property PACKAGE_PIN F6 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN F5 [get_ports sfp_refclk_n]

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

create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# Clock domains: sys clk, refclk-derived TX clocks, and one recovered RX clock per cage.
# All crossings in top.v go through synchronisers or Gray-coded counters.
set_clock_groups -asynchronous \
  -group [get_clocks sys_clk] \
  -group [get_clocks -include_generated_clocks sfp_refclk] \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins -hier -filter {NAME =~ *gt0_gtx10g_i*gtxe2_i/RXOUTCLK}]] \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins -hier -filter {NAME =~ *gt1_gtx10g_i*gtxe2_i/RXOUTCLK}]] \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins -hier -filter {NAME =~ *gtxe2_i/TXOUTCLK}]]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
