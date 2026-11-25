# Capture the MIG app interface ILA (build.tcl ... ila) during a memtest.
# Usage: vivado -mode batch -source ila_capture.tcl -tclargs [host:port] [wr|rd] [ltx]
#   wr: trigger on the first memtest write command, rd: on the first memtest read command.
# Writes ila_<mode>.csv next to this script. Start the memtest within 2 minutes after "ARMED".
set url  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "localhost:3122"}]
set mode [expr {[llength $argv] > 1 ? [lindex $argv 1] : "wr"}]
set d [file normalize [file dirname [info script]]]
set ltx [expr {[llength $argv] > 2 ? [lindex $argv 2] : "$d/build/top.ltx"}]
open_hw
connect_hw_server -url $url
set dev ""
foreach t [get_hw_targets] {
  open_hw_target $t
  set dev [lindex [get_hw_devices -quiet xcku5p*] 0]
  if {$dev ne ""} { break }
  close_hw_target $t
}
if {$dev eq ""} { error "No xcku5p on any JTAG target of $url" }
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev
set ila [lindex [get_hw_ilas] 0]
puts "ILA $ila probes: [get_hw_probes -of $ila]"
set_property CONTROL.TRIGGER_POSITION 64 $ila
set_property CONTROL.DATA_DEPTH 4096 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes dbg_mt_sel -of $ila]
set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes dbg_app_en -of $ila]
set_property TRIGGER_COMPARE_VALUE [expr {$mode eq "rd" ? "eq3'h1" : "eq3'h0"}] [get_hw_probes dbg_app_cmd -of $ila]
set_property CONTROL.TRIGGER_CONDITION AND $ila
run_hw_ila $ila
puts "ARMED ($mode): start the memtest now"
if {[catch {wait_on_hw_ila -timeout 2 $ila} e]} { puts "no trigger: $e"; exit 1 }
upload_hw_ila_data $ila
write_hw_ila_data -force -csv_file $d/ila_$mode.csv [current_hw_ila_data]
puts "WROTE $d/ila_$mode.csv"
