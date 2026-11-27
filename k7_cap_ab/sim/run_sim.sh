#!/bin/sh
# Behavioural sim of cap_top (both capture inputs, merge, DMA writer) with Vivado 2024.2 xsim.
# Linux: uses xvlog/xelab/xsim from PATH (source settings64.sh) or /opt/Xilinx/Vivado/2024.2.
# Windows (Git Bash): falls back to C:\Xilinx\Vivado\2024.2\bin\*.bat.
set -e
cd "$(dirname "$0")"
if command -v xvlog >/dev/null 2>&1; then X=""; S=""
elif [ -x /opt/Xilinx/Vivado/2024.2/bin/xvlog ]; then X=/opt/Xilinx/Vivado/2024.2/bin/; S=""
else X=/c/Xilinx/Vivado/2024.2/bin/; S=.bat; fi
R=../rtl
E=$R/verilog-ethernet
${X}xvlog$S -sv tb_cap.sv $R/cap_top.v $R/cap_port.v $R/cap_merge.v $R/cap_ingress.v $R/cap_testgen.v \
  $R/cap_dma.v $R/afifo.v $E/axis_xgmii_rx_64.v $E/lfsr.v > xvlog.out 2>&1 || { cat xvlog.out; exit 1; }
${X}xelab$S -debug off tb_cap -s tb_cap > xelab.out 2>&1 || { cat xelab.out; exit 1; }
${X}xsim$S tb_cap -R | grep -v "^#\|^INFO\|^Vivado\|^\*\*\*\|^Copyright\|^$\|Time resolution\|^source\|^ *$"
