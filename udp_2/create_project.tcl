################################################################################
# Script: create_project.tcl
# Description: Creates Vivado 2017.4 project for UDP packet sender
# Target Device: Arty A7-35 (xc7a35ticsg324-1L)
################################################################################

# Set project name and directory
set project_name "udp_sender"
set project_dir "./${project_name}"

# Create project
create_project ${project_name} ${project_dir} -part xc7a35ticsg324-1L -force

# Set project properties
set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]
set_property default_lib work [current_project]

# Add source files
add_files -norecurse {
    udp_sender_top.v
    clk_divider_4x.v
    udp_packet_gen.v
    mii_tx.v
}

# Add constraint file
add_files -fileset constrs_1 -norecurse Arty-A7-35-Master.xdc

# Set top module
set_property top udp_sender_top [current_fileset]

# Update compile order
update_compile_order -fileset sources_1

# Create IP directory (if needed for clocking wizard)
file mkdir ${project_dir}/${project_name}.srcs/sources_1/ip

puts "Project created successfully!"
puts "Project location: ${project_dir}"
puts ""
puts "Next steps:"
puts "1. Open the project in Vivado"
puts "2. Run synthesis and implementation"
puts "3. Generate bitstream"
puts "4. Program the device"

