# program.tcl - load the bitstream into the FPGA over the on-board USB-JTAG.
# (Volatile: lost on power cycle. For flash boot run scripts/flash.tcl.)
#
# Usage (from the project root):
#   vivado -mode batch -source scripts/program.tcl [-tclargs <file.bit>]

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set bit        "$root_dir/bin/blink.bit"

if {[info exists argv] && [llength $argv] > 0} {
    set bit [file normalize [lindex $argv 0]]
}
if {![file exists $bit]} {
    puts "ERROR: $bit not found - run scripts/build.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a35t*] 0]
if {$dev eq ""} {
    puts "ERROR: no xc7a35t on the JTAG chain - board connected and powered?"
    exit 1
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "INFO: programmed $dev with $bit"
close_hw_manager
