## Second flash of a dual QSPI (x8) pair: read by build.tcl only with -tclargs dual.
## Pins are fixed by the silicon (bank 65 multi-function). This board has no second flash.
set_property PACKAGE_PIN U22 [get_ports flash2_cs_n]
set_property PACKAGE_PIN N23 [get_ports {flash2_dq[0]}]
set_property PACKAGE_PIN P23 [get_ports {flash2_dq[1]}]
set_property PACKAGE_PIN R20 [get_ports {flash2_dq[2]}]
set_property PACKAGE_PIN R21 [get_ports {flash2_dq[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {flash2_cs_n flash2_dq[*]}]
set_property PULLUP true [get_ports {flash2_dq[*]}]
set_false_path -to [get_ports {flash2_cs_n flash2_dq[*]}]
set_false_path -from [get_ports {flash2_dq[*]}]
