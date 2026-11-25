# Non-project build: vivado -mode batch -source build.tcl
# Vivado 2017.4. ip/ is copied from k7_cap.
set d [file normalize [file dirname [info script]]]
cd $d
file mkdir build
create_project -in_memory -part xc7k325tffg676-2
read_ip [list $d/ip/pcie_x4/pcie_x4.xci $d/ip/jtag_axi_m/jtag_axi_m.xci]
set_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
read_verilog [glob $d/rtl/*.v]
read_xdc $d/top.xdc
synth_design -top top
write_checkpoint -force build/synth.dcp
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force build/routed.dcp
report_timing_summary -file build/timing.rpt
report_utilization -file build/util.rpt
report_clocks -file build/clocks.rpt
report_clock_interaction -file build/clock_interaction.rpt
report_methodology -file build/methodology.rpt
puts "RESULT WNS [get_property SLACK [get_timing_paths]] WHS [get_property SLACK [get_timing_paths -hold]]"
write_bitstream -force build/top.bit
write_debug_probes -force build/top.ltx
