# Non-project build (run gen_ip.tcl once first), Vivado 2024.2 only (Kintex UltraScale+ added):
#   C:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source build.tcl [-tclargs UI_MHZ]
# Outputs: build/top.bit, build/top.ltx (JTAG load only; no flash image is written)
set d [file normalize [file dirname [info script]]]
cd $d
file mkdir build
create_project -in_memory -part xcku5p-ffvb676-2-i
read_ip [list $d/ip/jtag_axi_m/jtag_axi_m.xci $d/ip/ddr4_0/ddr4_0.xci]
foreach f [get_files *.xci] { catch {set_property generate_synth_checkpoint false $f} }
generate_target all [get_ips]
read_verilog [glob $d/rtl/*.v]
read_xdc $d/top.xdc
set ui [expr {[llength $argv] > 0 && [string is integer [lindex $argv 0]] ? [lindex $argv 0] : 300}]
synth_design -top top -generic UI_MHZ=$ui
# debug hub (JTAG-AXI + MIG calibration debug) on the free-running board clock, so JTAG keeps
# working while the MIG is held in reset
set_property C_CLK_INPUT_FREQ_HZ 50000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk]
opt_design
puts "HUB CLOCK NET: [get_nets -of [get_pins -quiet dbg_hub/clk]]"
write_checkpoint -force build/opt.dcp
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
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "BUILD DONE  WNS $wns  WHS $whs"
