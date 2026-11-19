# Non-project build: vivado -mode batch -source build.tcl   (run gen_ip.tcl once first)
set d [file normalize [file dirname [info script]]]
cd $d
file mkdir build
create_project -in_memory -part xc7k325tffg676-2
read_ip [list $d/ip/gtx10g/gtx10g.xci $d/ip/status_vio/status_vio.xci]
set_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
read_verilog [concat [glob $d/rtl/*.v] [glob $d/rtl/verilog-ethernet/*.v]]
read_xdc $d/top.xdc
synth_design -top top
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file build/timing.rpt
report_utilization -file build/util.rpt
report_clocks -file build/clocks.rpt
report_clock_interaction -file build/clock_interaction.rpt
write_bitstream -force build/top.bit
write_debug_probes -force build/top.ltx
