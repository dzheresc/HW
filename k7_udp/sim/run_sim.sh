#!/bin/sh
# Behavioural sim of udp_counter (two instances back to back) with Vivado xsim.
set -e
cd "$(dirname "$0")"
V=/c/Xilinx/Vivado/2017.4/bin
E=../rtl/verilog-ethernet
$V/xvlog.bat tb_udp.v ../rtl/udp_counter.v $E/eth_mac_10g_fifo.v $E/eth_mac_10g.v $E/axis_xgmii_rx_64.v \
  $E/axis_xgmii_tx_64.v $E/lfsr.v $E/eth_axis_rx.v $E/eth_axis_tx.v $E/udp_complete_64.v $E/udp_checksum_gen_64.v \
  $E/udp_64.v $E/udp_ip_rx_64.v $E/udp_ip_tx_64.v $E/ip_complete_64.v $E/ip_64.v $E/ip_eth_rx_64.v \
  $E/ip_eth_tx_64.v $E/ip_arb_mux.v $E/arp.v $E/arp_cache.v $E/arp_eth_rx.v $E/arp_eth_tx.v $E/eth_arb_mux.v \
  $E/arbiter.v $E/priority_encoder.v $E/axis_fifo.v $E/axis_async_fifo.v $E/axis_async_fifo_adapter.v $E/axis_adapter.v > xvlog.out 2>&1 || { cat xvlog.out; exit 1; }
$V/xelab.bat -debug off tb_udp -s tb_udp > xelab.out 2>&1 || { cat xelab.out; exit 1; }
$V/xsim.bat tb_udp -R | grep -v "^#\|^INFO\|^Vivado\|^\*\*\*\|^Copyright\|^$\|Time resolution\|^source\|^ *$"
