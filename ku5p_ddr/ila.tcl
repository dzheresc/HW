# Insert an ILA on the mark_debug nets of top.v (`define ILA), clocked by the MIG ui_clk.
# Sourced by build.tcl after synth_design when run with the "ila" argument.
set all [get_nets -hier -filter {MARK_DEBUG == 1}]
puts "MARK_DEBUG nets: [llength $all]  [lrange [lsort $all] 0 40]"
set nets {}
foreach n $all { if {[string match "dbg_*" [regsub {^.*/} $n {}]]} { lappend nets $n } }
set nets [lsort $nets]
puts "ILA nets: [llength $nets]"
create_debug_core u_ila ila
set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila]
set_property C_TRIGIN_EN false [get_debug_cores u_ila]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_ila]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila]
set_property port_width 1 [get_debug_ports u_ila/clk]
connect_debug_port u_ila/clk [get_nets ui_clk]
# group bus bits by base name
array set grp {}
foreach n $nets {
  set base [regsub {\[\d+\]$} $n {}]
  lappend grp($base) $n
}
set first 1
foreach base [lsort [array names grp]] {
  set bits [lsort -dictionary $grp($base)]
  if {!$first} { create_debug_port u_ila probe }
  set p [lindex [get_debug_ports u_ila/probe*] end]
  set_property port_width [llength $bits] $p
  connect_debug_port $p $bits
  puts "ILA probe $p = $base ([llength $bits])"
  set first 0
}
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets ui_clk]
