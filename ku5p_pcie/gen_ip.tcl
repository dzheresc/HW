# Generate IP once: vivado -mode batch -source gen_ip.tcl [-tclargs PART [QUAD [WIDTH SPEED IFW FREQ]]]
# Needs a Vivado with Kintex UltraScale+ device support (oldgamer: /opt/Xilinx/Vivado/2017.4).
#
# PART  default xcku5p-ffvb676-1-e (vendor demo project; chip is XCKU5P-1FFVB676)
# QUAD  default GTY_Quad_225: x8 on GTYE4_CHANNEL_X0Y0..X0Y7 (quads 224-225), as in the
#       vendor XDMA demo (lane 0 rx = F2 ... lane 7 rx = Y2)
# Link  default Gen3 x8, 256-bit AXI-ST @ 250 MHz (what the vendor XDMA image trains to).
#       top.v's LANES/DATA_W must match (build.tcl passes them as generics).
set d [file normalize [file dirname [info script]]]
set part  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xcku5p-ffvb676-1-e"}]
set quad  [expr {[llength $argv] > 1 ? [lindex $argv 1] : "GTY_Quad_225"}]
set width [expr {[llength $argv] > 2 ? [lindex $argv 2] : "X8"}]
set speed [expr {[llength $argv] > 3 ? [lindex $argv 3] : "8.0_GT/s"}]
set ifw   [expr {[llength $argv] > 4 ? [lindex $argv 4] : "256_bit"}]
set freq  [expr {[llength $argv] > 5 ? [lindex $argv 5] : "250"}]
create_project -in_memory -part $part
file mkdir $d/ip

# PCIe endpoint (pcie4_uscale_plus): 10ee:9021, BAR0 = 4 KB 32-bit memory, no interrupts
file delete -force $d/ip/pcie_ku
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -module_name pcie_ku -dir $d/ip
set ip [get_ips pcie_ku]
set cfg [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH $width CONFIG.PL_LINK_CAP_MAX_LINK_SPEED $speed \
  CONFIG.axisten_if_width $ifw CONFIG.axisten_freq $freq \
  CONFIG.AXISTEN_IF_RC_STRADDLE {false} \
  CONFIG.REF_CLK_FREQ {100_MHz} \
  CONFIG.PF0_DEVICE_ID {9021} CONFIG.PF0_SUBSYSTEM_VENDOR_ID {10EE} CONFIG.PF0_SUBSYSTEM_ID {0007} \
  CONFIG.PF0_CLASS_CODE {058000} \
  CONFIG.pf0_bar0_enabled {true} CONFIG.pf0_bar0_type {Memory} CONFIG.pf0_bar0_64bit {false} \
  CONFIG.pf0_bar0_prefetchable {false} CONFIG.pf0_bar0_scale {Kilobytes} CONFIG.pf0_bar0_size {4} \
  CONFIG.PF0_INTERRUPT_PIN {NONE} CONFIG.pf0_msi_enabled {false} CONFIG.pf0_msix_enabled {false} \
]
set_property -dict $cfg $ip
if {$quad ne ""} {
  set_property -dict [list CONFIG.en_gt_selection {true} CONFIG.select_quad $quad] $ip
}
# IDs last: changing link/quad settings re-derives the default device ID
set_property -dict [list CONFIG.PF0_DEVICE_ID {9021} CONFIG.PF0_SUBSYSTEM_VENDOR_ID {10EE} CONFIG.PF0_SUBSYSTEM_ID {0007}] $ip
generate_target all $ip

# JTAG-to-AXI master for register access when the PCIe link is not available
file delete -force $d/ip/jtag_axi_m
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_m -dir $d/ip
set_property -dict [list CONFIG.PROTOCOL {2} CONFIG.M_AXI_ADDR_WIDTH {32} CONFIG.M_AXI_DATA_WIDTH {32}] [get_ips jtag_axi_m]
generate_target all [get_ips jtag_axi_m]

foreach p {CONFIG.pcie_blk_locn CONFIG.select_quad CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH CONFIG.PL_LINK_CAP_MAX_LINK_SPEED
           CONFIG.axisten_if_width CONFIG.axisten_freq CONFIG.PF0_DEVICE_ID CONFIG.pf0_bar0_size} {
  puts "CHK $p = [get_property $p $ip]"
}
