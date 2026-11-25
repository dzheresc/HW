# build.tcl - synthesis + implementation + bitstream, batch mode.
# Creates the project first if vivado/blink.xpr does not exist.
#
# Usage (from the project root):
#   vivado -mode batch -source scripts/build.tcl
# Output: bin/blink.bit, bin/utilization.rpt, bin/timing_summary.rpt

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set proj_name  "blink"
set proj_dir   "$root_dir/vivado"
set xpr        "$proj_dir/$proj_name.xpr"
set out_dir    "$root_dir/bin"
set jobs       4

if {[file exists $xpr]} {
    open_project $xpr
} else {
    puts "INFO: $xpr not found - creating project"
    set argv {}
    source "$script_dir/create_project.tcl"
}

reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

set status [get_property STATUS [get_runs impl_1]]
if {![string match "write_bitstream Complete!" $status]} {
    puts "ERROR: impl_1 finished with status '$status'"
    exit 1
}

file mkdir $out_dir
file copy -force "$proj_dir/$proj_name.runs/impl_1/$proj_name.bit" "$out_dir/$proj_name.bit"

open_run impl_1
report_utilization    -file "$out_dir/utilization.rpt"
report_timing_summary -file "$out_dir/timing_summary.rpt" -delay_type min_max -max_paths 10

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "INFO: bitstream: $out_dir/$proj_name.bit"
puts "INFO: timing: WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met"
    exit 1
}
