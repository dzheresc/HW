# Free GT wizard: GTX for 10GBASE-R, raw (no internal gearbox), 64-bit fabric / 32-bit internal.
set d [file normalize [file dirname [info script]]]
create_project -in_memory -part xc7k325tffg676-2
file delete -force $d/ip/gtx10g
file mkdir $d/ip
create_ip -name gtwizard -vendor xilinx.com -library ip -module_name gtx10g -dir $d/ip
set ip [get_ips gtx10g]
set_property -dict [list CONFIG.identical_protocol_file {10GBASE-R} CONFIG.gt0_val_protocol_file {10GBASE-R}] $ip
set_property -dict [list \
  CONFIG.gt0_val_encoding {None} CONFIG.gt0_val_decoding {None} \
  CONFIG.gt0_val_tx_data_width {64} CONFIG.gt0_val_tx_int_datawidth {32} \
  CONFIG.gt0_val_rx_data_width {64} CONFIG.gt0_val_rx_int_datawidth {32} \
  CONFIG.gt0_val_tx_refclk {REFCLK1_Q1} CONFIG.gt0_val_rx_refclk {REFCLK1_Q1} \
  CONFIG.gt0_val_drp_clock {100} \
  CONFIG.gt0_val {false} CONFIG.gt6_val {true} CONFIG.gt7_val {true} ] $ip

generate_target all $ip

# JTAG status readout / debug controls
file delete -force $d/ip/status_vio
create_ip -name vio -vendor xilinx.com -library ip -module_name status_vio -dir $d/ip
set v [get_ips status_vio]
set_property -dict [list CONFIG.C_NUM_PROBE_IN {11} CONFIG.C_NUM_PROBE_OUT {4} \
  CONFIG.C_PROBE_IN0_WIDTH {16} CONFIG.C_PROBE_IN1_WIDTH {8} CONFIG.C_PROBE_IN2_WIDTH {8} \
  CONFIG.C_PROBE_IN3_WIDTH {32} CONFIG.C_PROBE_IN4_WIDTH {32} CONFIG.C_PROBE_IN5_WIDTH {32} \
  CONFIG.C_PROBE_IN6_WIDTH {32} CONFIG.C_PROBE_IN7_WIDTH {32} CONFIG.C_PROBE_IN8_WIDTH {32} \
  CONFIG.C_PROBE_IN9_WIDTH {32} CONFIG.C_PROBE_IN10_WIDTH {32} \
  CONFIG.C_PROBE_OUT0_WIDTH {1} CONFIG.C_PROBE_OUT1_WIDTH {1} CONFIG.C_PROBE_OUT2_WIDTH {2} \
  CONFIG.C_PROBE_OUT3_WIDTH {2}] $v
generate_target all $v
