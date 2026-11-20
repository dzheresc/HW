# Volatile JTAG programming of $KU_BUILD/top.bit (default build/) through hw_server, then optionally
# run a JTAG-AXI command (jtag_flash.tcl procs) against the registers.
# Usage: vivado -mode batch -source program.tcl -tclargs [host:port] [noprog] ["tcl cmd"]
# Run with a Vivado that has Kintex UltraScale+ support (oldgamer 2017.4; the hw_server on localhost:3121 sees both cables).
# The shed hw_server also serves the K7's cable: this picks the target whose
# chain has an xcku5p, never the first target blindly.
set url [expr {[llength $argv] > 0 ? [lindex $argv 0] : "localhost:3121"}]
set noprog [expr {[lsearch $argv noprog] >= 0}]
set d [file normalize [file dirname [info script]]]
set bdir [expr {[info exists ::env(KU_BUILD)] ? $::env(KU_BUILD) : "build"}]
set bit $bdir/top.bit; set ltx $bdir/top.ltx
puts "bitstream: $d/$bit"
open_hw
connect_hw_server -url $url
set dev ""
foreach t [get_hw_targets] {
  open_hw_target $t
  set dev [lindex [get_hw_devices -quiet xcku5p*] 0]
  if {$dev ne ""} { puts "KU5P on target $t"; break }
  close_hw_target $t
}
if {$dev eq ""} { error "No xcku5p on any JTAG target of $url" }
current_hw_device $dev
set_property PROBES.FILE $d/$ltx $dev
set_property FULL_PROBES.FILE $d/$ltx $dev
if {!$noprog} {
  set_property PROGRAM.FILE $d/$bit $dev
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
