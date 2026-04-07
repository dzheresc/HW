create_clock -period 5.000 -name sys_clk_p [get_ports sys_clk_p]

set_property PACKAGE_PIN T24 [get_ports sys_clk_p]
set_property PACKAGE_PIN U24 [get_ports sys_clk_n]
#set_property IOSTANDARD DIFF_SSTL12 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL12_DCI [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL12_DCI [get_ports sys_clk_n]

#set_property PACKAGE_PIN K10 [get_ports sys_rst_n]
#set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

#set_property PACKAGE_PIN H9 [get_ports led]
#set_property IOSTANDARD LVCMOS33 [get_ports led]

set_property PACKAGE_PIN H9 [get_ports {led[0]}]
set_property PACKAGE_PIN J9 [get_ports {led[1]}]
set_property PACKAGE_PIN G11 [get_ports {led[2]}]
set_property PACKAGE_PIN H11 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

