# Volatile JTAG load of build/top.bit (no flash access), then the DDR demo over JTAG-to-AXI.
# Usage (Dell, board on its USB-C JTAG):
#   C:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source program.tcl -tclargs [host:port] [noprog] ["tcl cmd"]
# Default command: demo  (status, one burst write/read, burst_test, memtest over all 2 GB)
set url [expr {[llength $argv] > 0 && [string match *:* [lindex $argv 0]] ? [lindex $argv 0] : "localhost:3121"}]
set noprog [expr {[lsearch $argv noprog] >= 0}]
set cmd demo
foreach a $argv { if {![string match *:* $a] && $a ne "noprog"} { set cmd $a } }
set d [file normalize [file dirname [info script]]]
set bit $d/build/top.bit; set ltx $d/build/top.ltx
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
if {!$noprog} {
  set_property PROGRAM.FILE $bit $dev
  program_hw_devices $dev
  puts "DONE pin: [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
}
refresh_hw_device $dev
source $d/ddr_jtag.tcl
# MIG calibration report from the debug core (if present)
set mig [get_hw_migs -quiet]
if {$mig ne ""} {
  refresh_hw_mig $mig
  puts "MIG: CAL_STATUS=[get_property -quiet CAL_STATUS $mig]  [report_property -quiet -return_string $mig *STATUS*]"
}
wait_calib 5000
eval $cmd
close_hw_target
disconnect_hw_server
close_hw
