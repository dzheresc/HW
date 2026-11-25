# create_project.tcl - (re)create the Vivado project under ./vivado
#
# Usage (from the project root):
#   vivado -mode batch -source scripts/create_project.tcl [-tclargs <project_dir>]
# Afterwards open vivado/blink.xpr in the GUI, or run scripts/build.tcl.

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set proj_name  "blink"
set proj_dir   "$root_dir/vivado"
set part       "xc7a35ticsg324-1L"
set board_pat  "digilentinc.com:arty-a7-35:part0:*"

if {[info exists argv] && [llength $argv] > 0} {
    set proj_dir [file normalize [lindex $argv 0]]
}

create_project -force $proj_name $proj_dir -part $part

# Board part is optional: use it only if the Digilent board files are installed.
set boards [lsort -dictionary [get_board_parts -quiet $board_pat]]
if {[llength $boards] > 0} {
    set_property board_part [lindex $boards end] [current_project]
    puts "INFO: board_part = [lindex $boards end]"
} else {
    puts "INFO: Arty A7-35 board files not installed - using bare part $part"
}

set_property target_language    Verilog        [current_project]
set_property simulator_language Mixed          [current_project]
set_property default_lib        xil_defaultlib [current_project]

add_files -norecurse                    [glob "$root_dir/src/*.v"]
add_files -norecurse -fileset constrs_1 [glob "$root_dir/constrs/*.xdc"]
add_files -norecurse -fileset sim_1     [glob "$root_dir/sim/*.v"]

set_property top blink    [get_filesets sources_1]
set_property top tb_blink [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "INFO: project created: $proj_dir/$proj_name.xpr"
