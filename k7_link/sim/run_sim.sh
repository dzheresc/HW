#!/bin/sh
# Behavioural sim of link_port (MAC + responder) with Vivado 2024.2 xsim. Prints PASS or FAIL.
set -e
cd "$(dirname "$0")"
V=/c/Xilinx/Vivado/2024.2/bin
E=../rtl/verilog-ethernet
$V/xvlog.bat -sv tb_link.sv ../rtl/link_port.v ../rtl/echo_core.v $E/eth_mac_10g_fifo.v $E/eth_mac_10g.v \
  $E/axis_xgmii_rx_64.v $E/axis_xgmii_tx_64.v $E/lfsr.v $E/axis_fifo.v $E/axis_async_fifo.v \
  $E/axis_async_fifo_adapter.v $E/axis_adapter.v > xvlog.out 2>&1 || { cat xvlog.out; exit 1; }
$V/xelab.bat -debug off tb_link -s tb_link > xelab.out 2>&1 || { cat xelab.out; exit 1; }
$V/xsim.bat tb_link -R | grep -v "^#\|^INFO\|^Vivado\|^\*\*\*\|^Copyright\|^$\|Time resolution\|^source\|^ *$"
