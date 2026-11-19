# Generate IP once: vivado -mode batch -source gen_ip.tcl
set d [file normalize [file dirname [info script]]]
create_project -in_memory -part xc7k325tffg676-2
file mkdir $d/ip

# PCIe Gen2 x1 endpoint, 64-bit AXI-ST at 125 MHz, BAR0 = 4 KB 32-bit memory
file delete -force $d/ip/pcie_x1
create_ip -name pcie_7x -vendor xilinx.com -library ip -module_name pcie_x1 -dir $d/ip
set ip [get_ips pcie_x1]
set_property -dict [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.Maximum_Link_Width {X1} CONFIG.Link_Speed {5.0_GT/s} CONFIG.Trgt_Link_Speed {4'h2} \
  CONFIG.Interface_Width {64_bit} CONFIG.User_Clk_Freq {125} \
  CONFIG.PCIe_Blk_Locn {X0Y0} CONFIG.Ref_Clk_Freq {100_MHz} \
  CONFIG.Vendor_ID {10EE} CONFIG.Device_ID {7021} CONFIG.Subsystem_Vendor_ID {10EE} CONFIG.Subsystem_ID {0007} \
  CONFIG.Bar0_Enabled {true} CONFIG.Bar0_Type {Memory} CONFIG.Bar0_64bit {false} CONFIG.Bar0_Prefetchable {false} \
  CONFIG.Bar0_Scale {Kilobytes} CONFIG.Bar0_Size {4} \
  CONFIG.Legacy_Interrupt {NONE} \
  CONFIG.shared_logic_in_core {true} CONFIG.en_ext_clk {false} \
] $ip
generate_target all $ip

# JTAG-to-AXI master for register access when the PCIe link is not available
file delete -force $d/ip/jtag_axi_m
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_m -dir $d/ip
set_property -dict [list CONFIG.PROTOCOL {2} CONFIG.M_AXI_ADDR_WIDTH {32} CONFIG.M_AXI_DATA_WIDTH {32}] [get_ips jtag_axi_m]
generate_target all [get_ips jtag_axi_m]
foreach p {CONFIG.mode_selection CONFIG.Link_Speed CONFIG.User_Clk_Freq CONFIG.shared_logic_in_core CONFIG.en_ext_clk CONFIG.Legacy_Interrupt CONFIG.BAR0_Size_Vector} { puts "CHK $p = [get_property $p $ip]" }
