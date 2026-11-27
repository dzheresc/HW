# Register access over JTAG-to-AXI (same map as BAR0). Needs the PCIe refclk
# running (the register block is clocked by the PCIe user clock).
proc rd {a} {
  set t [create_hw_axi_txn -force rd_t [get_hw_axis hw_axi_1] -type read -address [format %08x $a] -len 1]
  run_hw_axi -quiet $t
  return [expr 0x[get_property DATA $t]]
}
proc wr {a v} {
  set t [create_hw_axi_txn -force wr_t [get_hw_axis hw_axi_1] -type write -address [format %08x $a] -len 1 -data [format %08x $v]]
  run_hw_axi -quiet $t
}
proc spi_wait {} { while {[rd 0x8] & 1} {} }
# send bytes (list), receive n bytes total (including sent ones)
proc spi_xfer {bytes n {keep 0}} {
  for {set i 0} {$i < [llength $bytes]} {incr i 4} {
    set w 0
    for {set j 0} {$j < 4} {incr j} {
      set b [lindex $bytes [expr $i+$j]]; if {$b eq ""} { set b 0 }
      set w [expr {$w | ($b << (8*$j))}]
    }
    wr [expr 0x400 + $i] $w
  }
  wr 0x10 [expr {$n | ($keep << 31)}]
  spi_wait
  set out {}
  for {set i 0} {$i < $n} {incr i 4} {
    set w [rd [expr 0x800 + $i]]
    for {set j 0} {$j < 4 && $i+$j < $n} {incr j} { lappend out [expr {($w >> (8*$j)) & 0xff}] }
  }
  return $out
}
proc hexl {l} { set s {}; foreach b $l { append s [format "%02X " $b] }; return $s }
proc status {} {
  puts [format "ID=%08X VER=%08X STATUS=%08X LINK=%08X" [rd 0] [rd 4] [rd 8] [rd 0x18]]
}
proc jedec {} {
  set r [spi_xfer {0x9F} 21]
  puts "JEDEC 9F: [hexl [lrange $r 1 end]]"
  set r [spi_xfer {0x05} 2];  puts [format "SR1=%02X" [lindex $r 1]]
  set r [spi_xfer {0x35} 2];  puts [format "35h(SR2/CR)=%02X" [lindex $r 1]]
  set r [spi_xfer {0x15} 2];  puts [format "15h(SR3/CR)=%02X" [lindex $r 1]]
  set r [spi_xfer {0x16} 2];  puts [format "16h(BAR)=%02X" [lindex $r 1]]
  set r [spi_xfer {0x5A 0 0 0 0} 13];  puts "SFDP: [hexl [lrange $r 5 end]]"
  set r [spi_xfer {0x03 0 0 0} 36];  puts "data@0: [hexl [lrange $r 4 end]]"
}
