## Only with gen_ip.tcl ... debug: clock the debug hub (JTAG-AXI + MIG calibration debug) from the MIG's dbg_clk
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
