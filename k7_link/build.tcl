# Non-project build: vivado -mode batch -source build.tcl   (Vivado 2024.2)
# ip/*.xci started as copies from k7_cap (2017.4) and were upgraded by upgrade_ip.tcl.
set d [file normalize [file dirname [info script]]]
cd $d
file mkdir build
create_project -in_memory -part xc7k325tffg676-2
read_ip [list $d/ip/gtx10g/gtx10g.xci $d/ip/status_vio/status_vio.xci \
              $d/ip/pcie_x4/pcie_x4.xci $d/ip/jtag_axi_m/jtag_axi_m.xci]
set_property generate_synth_checkpoint false [get_files *.xci]
generate_target all [get_ips]
read_verilog [concat [glob $d/rtl/*.v] [glob $d/rtl/verilog-ethernet/*.v]]
read_xdc $d/top.xdc
synth_design -top top
write_checkpoint -force build/synth.dcp
opt_design
place_design
phys_opt_design
route_design
phys_opt_design
write_checkpoint -force build/routed.dcp
report_timing_summary -file build/timing.rpt
report_utilization -file build/util.rpt
report_clock_interaction -file build/clock_interaction.rpt
report_cdc -file build/cdc.rpt
report_drc -file build/drc.rpt
write_bitstream -force build/top.bit
write_debug_probes -force build/top.ltx
write_cfgmem -force -format bin -interface SPIx4 -size 32 -loadbit "up 0x0 build/top.bit" -file build/top.bin
