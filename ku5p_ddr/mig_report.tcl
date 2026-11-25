# Read the MIG calibration report over JTAG (design built with gen_ip.tcl ... debug), no programming.
# Usage: vivado -mode batch -source mig_report.tcl -tclargs [host:port] [ltx]
set url [expr {[llength $argv] > 0 ? [lindex $argv 0] : "localhost:3122"}]
set d [file normalize [file dirname [info script]]]
set ltx [expr {[llength $argv] > 1 ? [lindex $argv 1] : "$d/build/top.ltx"}]
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
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev
puts "debug cores: [get_hw_ilas -quiet] [get_hw_axis -quiet] migs: [get_hw_migs -quiet]"
foreach m [get_hw_migs -quiet] {
  refresh_hw_mig $m
  foreach p [list_property $m] { puts "MIGPROP $p = [get_property $p $m]" }
  report_hw_mig $m
}
