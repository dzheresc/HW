# Volatile JTAG programming of build/blink.bit through a remote hw_server.
# Usage: vivado -mode batch -source program.tcl -tclargs [host:port]
set url [expr {[llength $argv] > 0 ? [lindex $argv 0] : "192.168.0.215:3121"}]
set bit [file normalize [file join [file dirname [info script]] build blink.bit]]

open_hw
connect_hw_server -url $url
puts "Targets: [get_hw_targets]"
open_hw_target [lindex [get_hw_targets] 0]
puts "Devices: [get_hw_devices]"
set dev [lindex [get_hw_devices xc7k325t*] 0]
if {$dev eq ""} { error "No xc7k325t on the JTAG chain" }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "DONE pin: [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
close_hw_target
disconnect_hw_server
close_hw
