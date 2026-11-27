## set up environment

$ source /opt/Xilinx/Vivado/2024.2/settings64.sh

## build bitstream

$ vivado -mode batch -source build.tcl

## identify target board

```
$ vivado -mode tcl
vivado% open_hw
Vivado% connect_hw_server -url localhost:3121
Vivado% get_hw_targets
localhost:3121/xilinx_tcf/Xilinx/0ABC01A localhost:3121/xilinx_tcf/Xilinx/13620207920da2
Vivado%
```

## 'program' the board

$ vivado -mode batch -source prog.tcl -tclargs 0ABC01A build_output/full_project.bit




Vivado 2024.2 rebuild, 2026-11-27 (agentic VM, `timed_build.sh`, one NUMA node, nothing loaded or flashed): build.tcl 3 min 12 s. WNS +4.253 ns, WHS +0.055 ns.
