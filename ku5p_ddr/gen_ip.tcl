# Generate IP once: vivado -mode batch -source gen_ip.tcl [-tclargs [DDR_PERIOD_PS]]
# Needs Kintex UltraScale+ support (oldgamer: /opt/Xilinx/Vivado/2017.4).
#
# pcie_ku    pcie4_uscale_plus as in ku5p_pcie (Gen3 x8 capable, 256-bit @ 250 MHz, 10ee:9021,
#            BAR0 4 KB) plus client tags for the DMA requester (RQ/RC).
# ddr4_0     MIG DDR4, native interface: two MT40A512M16HA-075E (x16, 8 Gb) = 32-bit, 2 GB,
#            100 MHz differential system clock on H23/H24 (bank 66).
#            DDR_PERIOD_PS default 833 (2400 MT/s, the vendor PCIe demo); 1250 = 1600 MT/s fallback.
# jtag_axi_m JTAG-to-AXI master for register access without PCIe.
set d [file normalize [file dirname [info script]]]
set part xcku5p-ffvb676-1-e
set tck  [expr {[llength $argv] > 0 ? [lindex $argv 0] : 833}]
create_project -in_memory -part $part
file mkdir $d/ip

file delete -force $d/ip/pcie_ku
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -module_name pcie_ku -dir $d/ip
set ip [get_ips pcie_ku]
set_property -dict [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X8} CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {8.0_GT/s} \
  CONFIG.axisten_if_width {256_bit} CONFIG.axisten_freq {250} \
  CONFIG.AXISTEN_IF_RC_STRADDLE {false} \
  CONFIG.axisten_if_enable_client_tag {true} \
  CONFIG.coreclk_freq {250} CONFIG.en_ext_clk {false} \
  CONFIG.REF_CLK_FREQ {100_MHz} \
  CONFIG.PF0_CLASS_CODE {058000} \
  CONFIG.pf0_bar0_enabled {true} CONFIG.pf0_bar0_type {Memory} CONFIG.pf0_bar0_64bit {false} \
  CONFIG.pf0_bar0_prefetchable {false} CONFIG.pf0_bar0_scale {Kilobytes} CONFIG.pf0_bar0_size {4} \
  CONFIG.PF0_INTERRUPT_PIN {NONE} CONFIG.pf0_msi_enabled {false} CONFIG.pf0_msix_enabled {false} \
] $ip
set_property -dict [list CONFIG.en_gt_selection {true} CONFIG.select_quad {GTY_Quad_226}] $ip
# IDs last (link/quad changes re-derive them); coreclk_freq must be forced back to 250
set_property -dict [list CONFIG.PF0_DEVICE_ID {9021} CONFIG.PF0_SUBSYSTEM_VENDOR_ID {10EE} CONFIG.PF0_SUBSYSTEM_ID {0007}] $ip
set_property CONFIG.coreclk_freq {250} $ip
generate_target all $ip

file delete -force $d/ip/jtag_axi_m
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_m -dir $d/ip
set_property -dict [list CONFIG.PROTOCOL {2} CONFIG.M_AXI_ADDR_WIDTH {32} CONFIG.M_AXI_DATA_WIDTH {32}] [get_ips jtag_axi_m]
generate_target all [get_ips jtag_axi_m]

file delete -force $d/ip/ddr4_0
create_ip -name ddr4 -vendor xilinx.com -library ip -module_name ddr4_0 -dir $d/ip
set m [get_ips ddr4_0]
set_property -dict [list \
  CONFIG.C0.DDR4_MemoryType {Components} \
  CONFIG.C0.DDR4_MemoryPart {MT40A512M16HA-075E} \
  CONFIG.C0.DDR4_DataWidth {32} \
  CONFIG.C0.DDR4_DataMask {DM_NO_DBI} \
  CONFIG.C0.DDR4_Ecc {false} \
  CONFIG.C0.DDR4_AxiSelection {false} \
  CONFIG.C0.DDR4_TimePeriod $tck \
] $m
# input clock: 100 MHz board oscillator; MIG lists the periods its PLL can use for this tCK
if {$tck == 833} {
  set_property -dict [list CONFIG.C0.DDR4_InputClockPeriod {9996} CONFIG.C0.DDR4_CasLatency {17} CONFIG.C0.DDR4_CasWriteLatency {12}] $m
} else {
  set_property -dict [list CONFIG.C0.DDR4_InputClockPeriod {10057} CONFIG.C0.DDR4_CasLatency {10} CONFIG.C0.DDR4_CasWriteLatency {9}] $m
}
set_property -dict [list CONFIG.System_Clock {Differential} CONFIG.Reference_Clock {Differential} \
  CONFIG.C0.DDR4_Mem_Add_Map {ROW_COLUMN_BANK} CONFIG.C0.DDR4_Ordering {Normal} CONFIG.Debug_Signal {Disable}] $m
generate_target all $m

foreach p {CONFIG.coreclk_freq CONFIG.axisten_if_enable_client_tag CONFIG.PF0_DEVICE_ID CONFIG.pf0_bar0_size} {
  puts "CHK $p = [get_property $p $ip]"
}
foreach p {CONFIG.C0.DDR4_MemoryPart CONFIG.C0.DDR4_DataWidth CONFIG.C0.DDR4_TimePeriod CONFIG.C0.DDR4_InputClockPeriod
           CONFIG.C0.DDR4_CasLatency CONFIG.C0.DDR4_CasWriteLatency CONFIG.C0.DDR4_AxiSelection} {
  puts "CHK $p = [get_property $p $m]"
}
