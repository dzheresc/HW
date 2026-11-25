# Non-project build (run gen_ip.tcl once first):
#   vivado -mode batch -source build.tcl [-tclargs [dual] [noleds]]
#   dual:   also drive the second flash of a dual QSPI pair (SPI_BUSWIDTH 8; not on this board)
#   noleds: leave the six user LEDs undriven
# Outputs: build/top.bit, build/top.ltx, and the flash image(s) build/top*.bin
# (write_cfgmem; with dual, build/top_primary.bin and build/top_secondary.bin).
set d [file normalize [file dirname [info script]]]
cd $d
file mkdir build
set dual [expr {[lsearch $argv dual] >= 0}]
set leds [expr {[lsearch $argv noleds] < 0}]
create_project -in_memory -part xcku5p-ffvb676-1-e
read_ip [list $d/ip/pcie_ku/pcie_ku.xci $d/ip/jtag_axi_m/jtag_axi_m.xci]
set part [get_property PART [lindex [get_ips pcie_ku] 0]]
if {$part ne "" && $part ne [get_property PART [current_project]]} { set_property PART $part [current_project] }
set_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
read_verilog [glob $d/rtl/*.v]
read_xdc $d/top.xdc
if {$dual} { read_xdc $d/dual_qspi.xdc }
set defs {}
if {$dual} { lappend defs DUAL_QSPI }
if {$leds} { lappend defs BOARD_LEDS }
set sargs [list -top top -generic LANES=8 -generic DATA_W=256]
foreach v $defs { lappend sargs -verilog_define $v }
synth_design {*}$sargs
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file build/timing.rpt
report_utilization -file build/util.rpt
report_clocks -file build/clocks.rpt
report_drc -file build/drc.rpt
set fp [open build/pins.txt w]
foreach p [lsort [get_ports]] { puts $fp "$p [get_property PACKAGE_PIN $p]" }
close $fp
if {$dual} {
  set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 8 [current_design]
} else {
  set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
}
write_bitstream -force build/top.bit
write_debug_probes -force build/top.ltx
# Flash image(s) for fpgaflash (board flash: MT25QU128, 16 MB).
if {$dual} {
  write_cfgmem -force -format bin -size 32 -interface SPIx8 -loadbit "up 0x0 build/top.bit" build/top.bin
} else {
  write_cfgmem -force -format bin -size 16 -interface SPIx4 -loadbit "up 0x0 build/top.bit" build/top.bin
}
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "BUILD DONE  part $part  dual $dual  WNS $wns"
