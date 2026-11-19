# Hardware projects

## Kintex-7 xc7k325t board

- `xdc/` - master pin constraints for the K7 325T board
- `k7_blink/` - LED blink built with the open-source openXC7 flow (yosys + nextpnr)
- `k7_10g/` - 10GBASE-R link bring-up on SFP A with the Xilinx PCS/PMA core
- `k7_10g_os/` - 10G link using a raw GTX plus open-source PCS (verilog-ethernet)
- `k7_pcie/` - PCIe Gen2 x1 endpoint with BAR0 registers and QSPI flash access
- `k7_nic/` - PCIe plus 10G Ethernet combined
- `k7_udp/` - 1 Hz UDP counter sender over 10G, controlled through BAR0

## Kintex UltraScale+ KU5P board

- `ku5p_pcie/` - PCIe endpoint with BAR registers and dual QSPI flash access

Build outputs (bitstreams, checkpoints, reports, generated IP) are not
committed. Run each project's `build.tcl` (or `make` for k7_blink) to rebuild;
IP is regenerated from the `.xci` files.
