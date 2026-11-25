# sim.tcl - run the self-checking testbench in xsim, batch mode.
# Look for "TB PASS" / "TB FAIL" in the output.
#
# Usage (from the project root):
#   vivado -mode batch -source scripts/sim.tcl

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set xpr        "$root_dir/vivado/blink.xpr"

if {[file exists $xpr]} {
    open_project $xpr
} else {
    set argv {}
    source "$script_dir/create_project.tcl"
}

launch_simulation
close_sim
