# Volatile JTAG programming of build/top.bit through a remote hw_server, then
# optionally run a JTAG-AXI script (jtag_flash.tcl procs) against the registers.
# Usage: vivado -mode batch -source program.tcl -tclargs [host:port] [noprog] ["tcl cmd"]
set url [expr {[llength $argv] > 0 ? [lindex $argv 0] : "192.168.0.215:3121"}]
set noprog [expr {[lsearch $argv noprog] >= 0}]
set d [file normalize [file dirname [info script]]]
open_hw
connect_hw_server -url $url
open_hw_target [lindex [get_hw_targets] 0]
set dev [lindex [get_hw_devices xc7k325t*] 0]
if {$dev eq ""} { error "No xc7k325t on the JTAG chain" }
current_hw_device $dev
set_property PROBES.FILE $d/build/top.ltx $dev
set_property FULL_PROBES.FILE $d/build/top.ltx $dev
if {!$noprog} {
  set_property PROGRAM.FILE $d/build/top.bit $dev
  program_hw_devices $dev
  puts "DONE pin: [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
  after 1000
}
refresh_hw_device $dev
source $d/jtag_flash.tcl
if {[llength $argv] > 2} { eval [lindex $argv 2] }
close_hw_target
disconnect_hw_server
close_hw
