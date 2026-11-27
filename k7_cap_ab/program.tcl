# Volatile JTAG programming of build/top.bit through a remote hw_server, then 10G status
# (VIO) and optionally a Tcl command, e.g. "status; jedec" (JTAG-to-AXI, jtag_flash.tcl).
# Usage: vivado -mode batch -source program.tcl -tclargs [host:port] [noprog] ["tcl cmd"]
set url [expr {[llength $argv] > 0 ? [lindex $argv 0] : "192.168.0.215:3121"}]
set noprog [expr {[lsearch $argv noprog] >= 0}]
set d [file normalize [file dirname [info script]]]
source [file join [file dirname [info script]] open_k7.tcl]
set dev [open_k7 $url]
set_property PROBES.FILE $d/build/top.ltx $dev
set_property FULL_PROBES.FILE $d/build/top.ltx $dev
if {!$noprog} {
  set_property PROGRAM.FILE $d/build/top.bit $dev
  program_hw_devices $dev
  puts "DONE pin: [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
  after 4000
}
refresh_hw_device $dev
source $d/jtag_flash.tcl
source $d/read_status.tcl
for {set i 0} {$i < 2} {incr i} { after 1500; show_status }
if {[llength $argv] > 2} { eval [lindex $argv 2] }
close_hw_target
disconnect_hw_server
close_hw
