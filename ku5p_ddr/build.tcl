# Non-project build (run gen_ip.tcl once first):
#   vivado -mode batch -source build.tcl
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
synth_design -top top -generic LANES=8 -generic DATA_W=256
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
