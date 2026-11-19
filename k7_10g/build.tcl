# Non-project build: vivado -mode batch -source build.tcl
set d [file normalize [file dirname [info script]]]
cd $d
file mkdir build
create_project -in_memory -part xc7k325tffg676-2
read_ip [list $d/ip/pcs_shared/pcs_shared.xci $d/ip/pcs_noshared/pcs_noshared.xci $d/ip/status_vio/status_vio.xci]
set_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
read_verilog $d/top.v
read_xdc $d/top.xdc
synth_design -top top
opt_design
place_design
route_design
report_timing_summary -file build/timing.rpt
report_utilization -file build/util.rpt
report_clocks -file build/clocks.rpt
write_bitstream -force build/top.bit
write_debug_probes -force build/top.ltx
