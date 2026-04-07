# Usage: vivado -mode batch -source program.tcl -tclargs <serial_number> <bit_file>

if { $argc != 2 } {
    puts "ERROR: Usage: vivado -mode batch -source program.tcl -tclargs <serial> <bitfile>"
    exit 1
}

set target_serial [lindex $argv 0]
set bitstream_file [lindex $argv 1]

open_hw
connect_hw_server -url localhost:3121

# 1. Select the specific target using the serial number from your list
set target [get_hw_targets -filter "NAME =~ */$target_serial"]

if {$target == ""} {
    puts "ERROR: Target with serial $target_serial not found!"
    disconnect_hw_server
    exit 1
}

puts "INFO: Connecting to target: $target"
open_hw_target $target

# 2. Identify the FPGA device on this target
# Usually index 0, but we refresh to be sure
set device [lindex [get_hw_devices] 0]
current_hw_device $device
refresh_hw_device

# 3. Program the bitstream
set_property PROGRAM.FILE $bitstream_file $device
program_hw_devices $device

# 4. Cleanup
close_hw_target
disconnect_hw_server
close_hw
puts "INFO: Programming of $target_serial complete."

