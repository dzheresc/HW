#!/bin/bash
# Behavioral sim of the DDR datapath (run on oldgamer): bash sim/run_ddr.sh
set -e
cd "$(dirname "$0")"
source /opt/Xilinx/Vivado/2017.4/settings64.sh > /dev/null
rm -rf xsim.dir
X=$XILINX_VIVADO/data/ip/xpm
xvlog -sv $X/xpm_fifo/hdl/xpm_fifo.sv $X/xpm_memory/hdl/xpm_memory.sv $X/xpm_cdc/hdl/xpm_cdc.sv tb_ddr.sv ../rtl/ddr_ctrl.v ../rtl/ddr_dma.v ../rtl/ddr_bridge.v ../rtl/ddr_memtest.v $XILINX_VIVADO/data/verilog/src/glbl.v > xvlog.log || { grep -E 'ERROR|WARN' xvlog.log; exit 1; }
xelab -debug off tb_ddr glbl -s tb_ddr > xelab.log || { grep -E 'ERROR' xelab.log; exit 1; }
xsim tb_ddr -R | grep -vE '^(INFO|\*\*\*\*|Time resolution|  \*\*)' | grep -v '^$'
