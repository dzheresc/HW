# Generate the PCIe core once: vivado -mode batch -source gen_ip.tcl
# (gtx10g, status_vio, jtag_axi_m are copied from k7_nic.)
set d [file normalize [file dirname [info script]]]
create_project -in_memory -part xc7k325tffg676-2
file mkdir $d/ip

# PCIe Gen2 x4 endpoint, 64-bit AXI-ST at 250 MHz, BAR0 = 4 KB 32-bit memory
file delete -force $d/ip/pcie_x4
create_ip -name pcie_7x -vendor xilinx.com -library ip -module_name pcie_x4 -dir $d/ip
set ip [get_ips pcie_x4]
set_property -dict [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.Maximum_Link_Width {X4} CONFIG.Link_Speed {5.0_GT/s} CONFIG.Trgt_Link_Speed {4'h2} \
  CONFIG.Interface_Width {64_bit} CONFIG.User_Clk_Freq {250} \
  CONFIG.PCIe_Blk_Locn {X0Y0} CONFIG.Ref_Clk_Freq {100_MHz} \
  CONFIG.Vendor_ID {10EE} CONFIG.Device_ID {7022} CONFIG.Subsystem_Vendor_ID {10EE} CONFIG.Subsystem_ID {0007} \
  CONFIG.Bar0_Enabled {true} CONFIG.Bar0_Type {Memory} CONFIG.Bar0_64bit {false} CONFIG.Bar0_Prefetchable {false} \
  CONFIG.Bar0_Scale {Kilobytes} CONFIG.Bar0_Size {4} \
  CONFIG.Max_Payload_Size {256_bytes} \
  CONFIG.Legacy_Interrupt {NONE} \
  CONFIG.shared_logic_in_core {true} CONFIG.en_ext_clk {false} \
] $ip
generate_target all $ip
foreach p {CONFIG.Maximum_Link_Width CONFIG.Link_Speed CONFIG.User_Clk_Freq CONFIG.Interface_Width CONFIG.Max_Payload_Size CONFIG.Device_ID} { puts "CHK $p = [get_property $p $ip]" }
