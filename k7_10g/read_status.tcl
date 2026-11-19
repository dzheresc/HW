# Status readout through status_vio. Needs an open hw target with probes loaded.
proc probe_val {pat} {
  set p [lindex [get_hw_probes -of_objects [get_hw_vios -of_objects [current_hw_device]] -filter "NAME == $pat"] 0]
  return [get_property INPUT_VALUE $p]
}
proc hx {v} { return [expr 0x$v] }
proc show_status {} {
  set vio [lindex [get_hw_vios -of_objects [current_hw_device]] 0]
  refresh_hw_vio $vio
  set misc [hx [probe_val misc]]
  set csa  [hx [probe_val cs_a_s]]
  set csb  [hx [probe_val cs_b_s]]
  puts [format "coreclk %d Hz | qplllock %d resetdone_a %d reset %d txrd_b %d rxrd_b %d" \
    [hx [probe_val hz_core]] [expr ($misc>>1)&1] [expr ($misc>>2)&1] [expr ($misc>>3)&1] [expr ($misc>>4)&1] [expr ($misc>>5)&1]]
  puts [format "SFP A: block_lock %d core_status 0x%02x | rx idle/s %d  local-fault/s %d  remote-fault/s %d" \
    [expr $csa&1] $csa [hx [probe_val r_idle_a]] [hx [probe_val r_lf_a]] [hx [probe_val r_rf_a]]]
  puts [format "SFP B: block_lock %d core_status 0x%02x | rx idle/s %d  local-fault/s %d  remote-fault/s %d" \
    [expr $csb&1] $csb [hx [probe_val r_idle_b]] [hx [probe_val r_lf_b]] [hx [probe_val r_rf_b]]]
}
