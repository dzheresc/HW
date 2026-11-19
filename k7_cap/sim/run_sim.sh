#!/bin/sh
# Behavioural sim of cap_top (MAC RX, ingress, FIFOs, DMA writer) with Vivado xsim.
set -e
cd "$(dirname "$0")"
V=/c/Xilinx/Vivado/2017.4/bin
R=../rtl
E=$R/verilog-ethernet
$V/xvlog.bat -sv tb_cap.sv $R/cap_top.v $R/cap_ingress.v $R/cap_testgen.v $R/cap_dma.v $R/afifo.v \
  $E/axis_xgmii_rx_64.v $E/lfsr.v > xvlog.out 2>&1 || { cat xvlog.out; exit 1; }
$V/xelab.bat -debug off tb_cap -s tb_cap > xelab.out 2>&1 || { cat xelab.out; exit 1; }
$V/xsim.bat tb_cap -R | grep -v "^#\|^INFO\|^Vivado\|^\*\*\*\|^Copyright\|^$\|Time resolution\|^source\|^ *$"
