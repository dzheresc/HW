# flash.tcl - build bin/blink.mcs from bin/blink.bit and write it to the
# Arty A7 quad-SPI flash so the design loads on power-up.  Ends by booting the
# FPGA from flash.
#
# Arty A7 boards shipped with different 128 Mbit flash chips depending on
# revision, so the script tries each known part until one matches the JEDEC ID.
# This board has a Micron MT25QL128 (detected 2026-10-17), so it is tried first.
#
# Usage (from the project root):
#   vivado -mode batch -source scripts/flash.tcl [-tclargs <file.bit>]

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set bit        "$root_dir/bin/blink.bit"
set candidates {
    mt25ql128-spi-x1_x2_x4
    s25fl128sxxxxxx0-spi-x1_x2_x4
    n25q128-3.3v-spi-x1_x2_x4
}

if {[info exists argv] && [llength $argv] > 0} {
    set bit [file normalize [lindex $argv 0]]
}
if {![file exists $bit]} {
    puts "ERROR: $bit not found - run scripts/build.tcl first"
    exit 1
}
set mcs "[file rootname $bit].mcs"

# --- 1. memory configuration file (16 MB flash, x4 SPI, bitstream at 0) ------
write_cfgmem -force -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x00000000 $bit" -file $mcs
puts "INFO: wrote $mcs"

# --- 2. connect ---------------------------------------------------------------
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

# --- 3. program flash, trying each candidate part -----------------------------
set done_part ""
foreach part $candidates {
    set cfgmem_part [lindex [get_cfgmem_parts -quiet $part] 0]
    if {$cfgmem_part eq ""} {
        puts "WARNING: cfgmem part '$part' unknown to this Vivado - skipped"
        continue
    }
    puts "INFO: trying flash part $part"

    set old [get_property PROGRAM.HW_CFGMEM $dev]
    if {$old ne ""} { delete_hw_cfgmem $old }
    create_hw_cfgmem -hw_device $dev $cfgmem_part
    set cfgmem [get_property PROGRAM.HW_CFGMEM $dev]

    set_property PROGRAM.ADDRESS_RANGE          {use_file}   $cfgmem
    set_property PROGRAM.FILES                  [list $mcs]  $cfgmem
    set_property PROGRAM.PRM_FILE               {}           $cfgmem
    set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none}  $cfgmem
    set_property PROGRAM.BLANK_CHECK            0            $cfgmem
    set_property PROGRAM.ERASE                  1            $cfgmem
    set_property PROGRAM.CFG_PROGRAM            1            $cfgmem
    set_property PROGRAM.VERIFY                 1            $cfgmem
    set_property PROGRAM.CHECKSUM               0            $cfgmem

    # load the indirect flash-programming bitstream into the FPGA
    create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
    program_hw_devices $dev
    refresh_hw_device -update_hw_probes false $dev

    if {[catch {program_hw_cfgmem -hw_cfgmem $cfgmem} err]} {
        puts "INFO: $part did not match / failed:\n$err"
        continue
    }
    set done_part $part
    break
}

if {$done_part eq ""} {
    puts "ERROR: flash programming failed for all candidate parts: $candidates"
    close_hw_manager
    exit 1
}
puts "INFO: flash programmed ($done_part) with $mcs"

# --- 4. boot the FPGA from flash ----------------------------------------------
boot_hw_device $dev
after 3000
refresh_hw_device -update_hw_probes false $dev
if {![catch {get_property REGISTER.IR.BIT5_DONE $dev} d]} {
    puts "INFO: after boot from flash: DONE = $d"
}
close_hw_manager
