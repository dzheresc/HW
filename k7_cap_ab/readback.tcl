# Independent full-flash readback through Vivado's JTAG SPI loader (replaces the FPGA design!).
# Usage: vivado -mode batch -source readback.tcl -tclargs host:port out.bin
set url [lindex $argv 0]; set out [lindex $argv 1]
source [file join [file dirname [info script]] open_k7.tcl]
set dev [open_k7 $url]
refresh_hw_device -update_hw_probes false $dev
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {s25fl256sxxxxxx0-spi-x1_x2_x4}] 0]
set m [get_property PROGRAM.HW_CFGMEM $dev]
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
readback_hw_cfgmem -force -hw_cfgmem $m -file $out -format bin -all
puts "READBACK DONE"
close_hw_target
disconnect_hw_server
