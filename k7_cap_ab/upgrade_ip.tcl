# One-off: upgrade the 2017.4 .xci copies in ip/ to the running Vivado's IP versions.
set d [file normalize [file dirname [info script]]]
create_project -in_memory -part xc7k325tffg676-2
foreach i {gtx10g status_vio pcie_x4 jtag_axi_m} { read_ip $d/ip/$i/$i.xci }
upgrade_ip [get_ips]
report_ip_status
generate_target all [get_ips]
foreach i [get_ips] { puts "IPS $i [get_property IPDEF $i] locked=[get_property IS_LOCKED $i]" }
