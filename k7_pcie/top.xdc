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

## PCIe
set_property PACKAGE_PIN E17 [get_ports pcie_perst_n]
set_property IOSTANDARD LVCMOS33 [get_ports pcie_perst_n]
set_property PULLUP true [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]
set_property PACKAGE_PIN H6 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN H5 [get_ports pcie_refclk_n]
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]
set_property PACKAGE_PIN J4 [get_ports {pci_exp_rxp[0]}]
# The IP's own XDC puts lane 0 on X0Y7 (an SFP cage on this board); override.
set_property LOC GTXE2_CHANNEL_X0Y3 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL}]

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

## Async domains
set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks -include_generated_clocks pcie_refclk]

## Configuration
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
