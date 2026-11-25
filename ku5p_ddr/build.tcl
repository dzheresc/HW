# Non-project build (run gen_ip.tcl once first):
#   vivado -mode batch -source build.tcl [-tclargs UI_MHZ]
# Outputs: build/top.bit, build/top.ltx, build/top.bin (flash image for fpgaflash)
set d [file normalize [file dirname [info script]]]
cd $d
file mkdir build
create_project -in_memory -part xcku5p-ffvb676-1-e
read_ip [list $d/ip/pcie_ku/pcie_ku.xci $d/ip/jtag_axi_m/jtag_axi_m.xci $d/ip/ddr4_0/ddr4_0.xci]
foreach f [get_files *.xci] { catch {set_property generate_synth_checkpoint false $f} }
generate_target all [get_ips]
read_verilog [glob $d/rtl/*.v]
read_xdc $d/top.xdc
if {[lsearch $argv debug] >= 0} { read_xdc $d/debug.xdc }   ;# with a gen_ip.tcl ... debug MIG
# ui_clk MHz reported in DDR_INFO (300 at 2400 MT/s; 156 for the 1250 MT/s MIG, gen_ip.tcl 1600)
set ui [expr {[llength $argv] > 0 && [string is integer [lindex $argv 0]] ? [lindex $argv 0] : 300}]
set defs {}
if {[lsearch $argv ila] >= 0} { lappend defs -verilog_define ILA }
synth_design -top top -generic LANES=8 -generic DATA_W=256 -generic UI_MHZ=$ui {*}$defs
if {[lsearch $argv ila] >= 0} { source $d/ila.tcl }
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file build/timing.rpt
report_utilization -file build/util.rpt
report_clocks -file build/clocks.rpt
report_clock_interaction -file build/clock_interaction.rpt
report_drc -file build/drc.rpt
set fp [open build/pins.txt w]
foreach p [lsort [get_ports]] { puts $fp "$p [get_property PACKAGE_PIN $p] [get_property IOSTANDARD $p]" }
close $fp
write_bitstream -force build/top.bit
write_debug_probes -force build/top.ltx
write_cfgmem -force -format bin -size 16 -interface SPIx4 -loadbit "up 0x0 build/top.bit" build/top.bin
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "BUILD DONE  WNS $wns  WHS $whs"
