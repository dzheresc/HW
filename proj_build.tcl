# Project-mode build for projects that ship only create_project.tcl (Vivado 2024.2).
# Run from the project directory: vivado -mode batch -source ../proj_build.tcl
source create_project.tcl
set_param general.maxThreads 8
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
puts "IMPL STATUS: $st"
if {![string match "write_bitstream Complete*" $st]} { error "build failed: $st" }
open_run impl_1
puts "BUILD DONE  WNS [get_property STATS.WNS [get_runs impl_1]]  WHS [get_property STATS.WHS [get_runs impl_1]]  bit [glob [get_property DIRECTORY [get_runs impl_1]]/*.bit]"
