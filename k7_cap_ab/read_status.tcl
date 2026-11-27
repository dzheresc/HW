# Status readout through status_vio. Needs an open hw target with probes loaded.
# Probes are named after the nets in top.v.
proc vio {} { return [lindex [get_hw_vios -of_objects [current_hw_device]] 0] }
proc probe {name} { return [lindex [get_hw_probes -of_objects [vio] -filter "NAME == $name || NAME == eth/$name"] 0] }
proc pv {name} { return [expr 0x[get_property INPUT_VALUE [probe $name]]] }
proc bit {v n} { return [expr ($v >> $n) & 1] }

# Drive a VIO output: set_ctl vio_rst 1 / vio_bitrev 1 / vio_rxpol 3 / vio_txpol 0
proc set_ctl {name val} {
  set p [probe $name]
  set_property OUTPUT_VALUE_RADIX UNSIGNED $p
  set_property OUTPUT_VALUE $val $p
  commit_hw_vio $p
}

proc show_status {} {
  refresh_hw_vio [vio]
  set m [pv misc]; set a [pv st_a]; set b [pv st_b]
  puts [format "qplllock %d tx_mmcm %d | tx_fsm A%d B%d rx_fsm A%d B%d | txrstdone A%d B%d rxrstdone A%d B%d | rx_mmcm A%d B%d" \
    [bit $m 0] [bit $m 1] [bit $m 2] [bit $m 3] [bit $m 4] [bit $m 5] [bit $m 6] [bit $m 7] [bit $m 8] [bit $m 9] [bit $m 10] [bit $m 11]]
  puts [format "tx pcs clk %d Hz, rx pcs clk A %d Hz" [pv hz_tx] [pv hz_rx_a]]
  puts [format "SFP A: block_lock %d high_ber %d rx_status %d errs %d | rx idle/s %d  local-fault/s %d  remote-fault/s %d" \
    [bit $a 0] [bit $a 1] [bit $a 2] [expr $a >> 3] [pv r_idle_a] [pv r_lf_a] [pv r_rf_a]]
  puts [format "SFP B: block_lock %d high_ber %d rx_status %d errs %d | rx idle/s %d  local-fault/s %d  remote-fault/s %d" \
    [bit $b 0] [bit $b 1] [bit $b 2] [expr $b >> 3] [pv r_idle_b] [pv r_lf_b] [pv r_rf_b]]
}
