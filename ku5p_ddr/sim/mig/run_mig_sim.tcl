# Behavioral sim of ddr_memtest on the real MIG RTL + Micron DDR4 models (MIG example design).
# Needs the example project: open_example_project for ip/ddr4_0 into ~/ku5p_ddr_ex (see README).
set d [file normalize [file dirname [info script]]]
open_project /home/denis/ku5p_ddr_ex/ddr4_0_ex/ddr4_0_ex.xpr
set f [get_files -quiet -of [get_filesets sim_1] *example_tb.sv]
if {$f ne ""} { remove_files -fileset sim_1 $f }
set f [get_files -quiet -of [get_filesets sources_1] *example_tb.sv]
if {$f ne ""} { remove_files $f }
add_files -fileset sim_1 [list $d/example_tb.sv $d/../../rtl/ddr_memtest.v]
set_property top sim_tb_top [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
launch_simulation -mode behavioral
run all
close_sim
