# Generate IP cores into ./ip: vivado -mode batch -source gen_ip.tcl
set d [file normalize [file dirname [info script]]]
create_project -in_memory -part xc7k325tffg676-2
file delete -force $d/ip
file mkdir $d/ip
# 10GBASE-R PCS/PMA. pcs_shared includes the QPLL + clocking; pcs_noshared reuses it.
foreach {name shared} {pcs_shared 1 pcs_noshared 0} {
  create_ip -name ten_gig_eth_pcs_pma -vendor xilinx.com -library ip -module_name $name -dir $d/ip
  set_property -dict [list CONFIG.MDIO_Management {false} CONFIG.base_kr {BASE-R} \
     CONFIG.SupportLevel $shared CONFIG.DClkRate {100}] [get_ips $name]
}
# JTAG status readout
create_ip -name vio -vendor xilinx.com -library ip -module_name status_vio -dir $d/ip
set_property -dict [list CONFIG.C_NUM_PROBE_IN {10} CONFIG.C_NUM_PROBE_OUT {1} \
  CONFIG.C_PROBE_IN0_WIDTH {8} CONFIG.C_PROBE_IN1_WIDTH {8} CONFIG.C_PROBE_IN2_WIDTH {8} \
  CONFIG.C_PROBE_IN3_WIDTH {32} CONFIG.C_PROBE_IN4_WIDTH {32} CONFIG.C_PROBE_IN5_WIDTH {32} \
  CONFIG.C_PROBE_IN6_WIDTH {32} CONFIG.C_PROBE_IN7_WIDTH {32} CONFIG.C_PROBE_IN8_WIDTH {32} \
  CONFIG.C_PROBE_IN9_WIDTH {32} CONFIG.C_PROBE_OUT0_WIDTH {1}] [get_ips status_vio]
generate_target all [get_ips]
