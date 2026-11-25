# Generate IP once: vivado -mode batch -source gen_ip.tcl [-tclargs [DDR_PERIOD_PS] [part=<memory part>]]
# Vivado 2024.2 on the Dell only (Denis: no older versions). Regenerate after a version change.
#
# ddr4_0     MIG DDR4, native interface: two MT40A512M16LY-062E (x16, 8 Gb) = 32-bit, 2 GB,
#            200 MHz differential system clock. DDR_PERIOD_PS default 833 (2400 MT/s, ui_clk
#            300 MHz); 1250 = 1600 MT/s fallback (ui_clk 200 MHz... see CHK lines for the value).
#            If the MIG catalog has no MT40A512M16LY-062E it falls back to MT40A512M16HA-075E
#            (same 8 Gb x16 organisation, slower speed bin = conservative timings).
#            Calibration debug is on (MIG cores visible in the Hardware Manager, hub on clk50).
# jtag_axi_m JTAG-to-AXI master (AXI4-Lite, 32-bit) for the registers.
set d [file normalize [file dirname [info script]]]
set part xcku5p-ffvb676-2-i
set tck 833
set mem MT40A512M16LY-062E
foreach a $argv {
  if {[string is integer -strict $a]} { set tck $a }
  if {[string match part=* $a]} { set mem [string range $a 5 end] }
}
create_project -in_memory -part $part
file mkdir $d/ip

file delete -force $d/ip/jtag_axi_m
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_m -dir $d/ip
set_property -dict [list CONFIG.PROTOCOL {2} CONFIG.M_AXI_ADDR_WIDTH {32} CONFIG.M_AXI_DATA_WIDTH {32}] [get_ips jtag_axi_m]
generate_target all [get_ips jtag_axi_m]

file delete -force $d/ip/ddr4_0
create_ip -name ddr4 -vendor xilinx.com -library ip -module_name ddr4_0 -dir $d/ip
set m [get_ips ddr4_0]
set_property -dict [list CONFIG.C0.DDR4_MemoryType {Components} CONFIG.C0.DDR4_TimePeriod $tck] $m
# first part the catalog accepts: the board's part, the vendor example's, then the generic 8 Gb x16
foreach p [list $mem MT40A512M16LY-075 MT40A512M16HA-075E] {
  if {![catch {set_property CONFIG.C0.DDR4_MemoryPart $p $m}] && [get_property CONFIG.C0.DDR4_MemoryPart $m] eq $p} { break }
  puts "WARNING: memory part $p not accepted"
}
set_property -dict [list \
  CONFIG.C0.DDR4_DataWidth {32} \
  CONFIG.C0.DDR4_DataMask {DM_NO_DBI} \
  CONFIG.C0.DDR4_Ecc {false} \
  CONFIG.C0.DDR4_AxiSelection {false} \
] $m
# 200 MHz board clock: the MIG only offers input periods its PLL can make from this tCK
if {$tck == 833} {
  set_property -dict [list CONFIG.C0.DDR4_InputClockPeriod {4998} CONFIG.C0.DDR4_CasLatency {17} CONFIG.C0.DDR4_CasWriteLatency {12}] $m
} else {
  set_property -dict [list CONFIG.C0.DDR4_InputClockPeriod {5000} CONFIG.C0.DDR4_CasLatency {11} CONFIG.C0.DDR4_CasWriteLatency {11}] $m
}
set_property -dict [list CONFIG.System_Clock {Differential} CONFIG.Reference_Clock {Differential} \
  CONFIG.C0.DDR4_Mem_Add_Map {ROW_COLUMN_BANK} CONFIG.C0.DDR4_Ordering {Normal} CONFIG.Debug_Signal {Enable}] $m
generate_target all $m

foreach p {CONFIG.C0.DDR4_MemoryPart CONFIG.C0.DDR4_DataWidth CONFIG.C0.DDR4_DataMask CONFIG.C0.DDR4_TimePeriod
           CONFIG.C0.DDR4_InputClockPeriod CONFIG.C0.DDR4_CasLatency CONFIG.C0.DDR4_CasWriteLatency
           CONFIG.C0.DDR4_AxiSelection CONFIG.C0.DDR4_AxiDataWidth CONFIG.C0.DDR4_nCK_TFAW CONFIG.C0.DDR4_isCustom
           CONFIG.C0.DDR4_BurstLength CONFIG.C0.DDR4_BurstType CONFIG.C0.DDR4_AxiAddressWidth CONFIG.Debug_Signal} {
  puts "CHK $p = [get_property -quiet $p $m]"
}
puts "CHK ui_clk period: [get_property -quiet CONFIG.C0.DDR4_TimePeriod $m] ps x 4"
