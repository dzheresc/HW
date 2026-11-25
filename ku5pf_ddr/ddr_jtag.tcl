# DDR4 read/write over JTAG-to-AXI. Sourced by program.tcl (or in the Hardware Manager Tcl console
# after programming: source C:/develop/ku5pf_ddr/ddr_jtag.tcl). Register map: rtl/ddr_regs.v.
#
#   status                 ID, calibration, ui_clk frequency
#   ddr_wr <addr> <list>   write one 32-byte burst (8 x 32-bit words, word 0 = first beat)
#   ddr_rd <addr>          read one 32-byte burst -> list of 8 words
#   burst_test [n]         n bursts with a distinct value per beat, prints any beat mismatch
#                          (shows half-burst / BC4-vs-BL8 or beat-order problems directly)
#   memtest [base] [len] [mode]   in-fabric test at full rate (default all 2 GB, all 4 modes)
#   recal                  pulse the MIG reset and wait for calibration
proc rd {a} {
  set t [create_hw_axi_txn -force rd_t [get_hw_axis hw_axi_1] -type read -address [format %08x $a] -len 1]
  run_hw_axi -quiet $t
  return [expr 0x[get_property DATA $t]]
}
proc wr {a v} {
  set t [create_hw_axi_txn -force wr_t [get_hw_axis hw_axi_1] -type write -address [format %08x $a] -len 1 -data [format %08x $v]]
  run_hw_axi -quiet $t
}

proc status {} {
  set st [rd 0xC00]
  puts [format "ID=%08X VER=%08X  DDR_STATUS=%08X (calib=%d ui_rst=%d mt_busy=%d mt_done=%d)  ui_clk=%.3f MHz" \
    [rd 0x0] [rd 0x4] $st [expr {$st & 1}] [expr {($st >> 1) & 1}] [expr {($st >> 2) & 1}] [expr {($st >> 3) & 1}] \
    [expr {[rd 0x10] / 1000.0}]]
  return [expr {$st & 1}]
}

proc wait_calib {{ms 5000}} {
  for {set i 0} {$i < $ms / 50} {incr i} {
    if {[rd 0xC00] & 1} { return 1 }
    after 50
  }
  return 0
}

proc recal {} {
  wr 0xC08 1; after 10; wr 0xC08 0
  set ok [wait_calib]
  puts [expr {$ok ? "calibration done" : "CALIBRATION NOT DONE (check the MIG core in the Hardware Manager)"}]
  return $ok
}

proc sa_wait {} {
  for {set i 0} {$i < 1000} {incr i} { if {!([rd 0xC84] & 1)} { return } }
  error "single access stuck (DDR not calibrated?)"
}

proc ddr_wr {a words} {
  if {$a & 31} { error "address must be 32-byte aligned" }
  for {set j 0} {$j < 8} {incr j} { wr [expr {0xCA0 + 4*$j}] [lindex $words $j] }
  wr 0xC80 $a
  wr 0xC84 2
  sa_wait
}

proc ddr_rd {a} {
  if {$a & 31} { error "address must be 32-byte aligned" }
  wr 0xC80 $a
  wr 0xC84 1
  sa_wait
  set out {}
  for {set j 0} {$j < 8} {incr j} { lappend out [rd [expr {0xCA0 + 4*$j}]] }
  return $out
}

proc hexw {l} { set s {}; foreach w $l { append s [format "%08X " $w] }; return $s }

# beat j of the burst at address a holds  (a + 4*j) ^ salt  : every beat distinct and address-tagged
proc burst_test {{n 64} {salt 0xA5000000}} {
  set addrs {}
  for {set i 0} {$i < $n} {incr i} {
    # spread over rows, banks and both chips: walk one address bit at a time, then pseudo-random
    if {$i < 26} { set a [expr {32 << $i}] } else { set a [expr {(($i * 2654435761) & 0x7FFFFFFF) & ~31}] }
    if {$i == 0} { set a 0 }
    lappend addrs $a
  }
  foreach a $addrs {
    set w {}
    for {set j 0} {$j < 8} {incr j} { lappend w [expr {(($a + 4*$j) ^ $salt) & 0xFFFFFFFF}] }
    ddr_wr $a $w
  }
  set bad 0
  foreach a $addrs {
    set got [ddr_rd $a]
    set exp {}
    for {set j 0} {$j < 8} {incr j} { lappend exp [expr {(($a + 4*$j) ^ $salt) & 0xFFFFFFFF}] }
    if {$got ne $exp} {
      incr bad
      if {$bad <= 8} {
        puts [format "MISMATCH @%08X" $a]
        puts "  exp: [hexw $exp]"
        puts "  got: [hexw $got]"
      }
    }
  }
  puts "burst_test: $n bursts, $bad bad"
  return $bad
}

proc memtest {{base 0} {len 0x80000000} {modes {0 1 2 3}}} {
  set tot 0
  foreach mode $modes {
    wr 0xC14 $base; wr 0xC18 $len; wr 0xC1C [expr {0x13572468 + $mode}]
    wr 0xC10 [expr {1 | 2 | 4 | ($mode << 4)}]
    set t0 [clock milliseconds]
    while {!([rd 0xC00] & 8)} {
      if {[clock milliseconds] - $t0 > 60000} { error "memtest timeout" }
      after 20
    }
    set errs [rd 0xC20]; set wc [rd 0xC24]; set rc [rd 0xC28]
    set mhz [expr {[rd 0x10] / 1000.0}]
    set gb [expr {$len / 1.0e9}]
    puts [format "memtest mode %d: %d errors  write %.2f GB/s  read %.2f GB/s" $mode $errs \
      [expr {$wc ? $gb / ($wc / ($mhz * 1e6)) : 0}] [expr {$rc ? $gb / ($rc / ($mhz * 1e6)) : 0}]]
    if {$errs} { puts [format "  first @%08X exp %08X got %08X" [rd 0xC2C] [rd 0xC30] [rd 0xC34]] }
    incr tot $errs
  }
  return $tot
}

proc demo {} {
  if {![status]} { puts "DDR not calibrated"; return }
  ddr_wr 0x100 {0x11111111 0x22222222 0x33333333 0x44444444 0x55555555 0x66666666 0x77777777 0x88888888}
  puts "read back @0x100: [hexw [ddr_rd 0x100]]"
  burst_test 64
  memtest
}
