################################################################################
# TCL Script to create UDP Sender project for Vivado 2017.4
# Target Device: Artix A7-35 (xc7a35ticsg324-1L)
################################################################################

# Set project variables
set project_name "udp_sender"
set project_dir "./${project_name}"
set part_name "xc7a35ticsg324-1L"

# Create project directory if it doesn't exist
file mkdir $project_dir

# Create project
create_project $project_name $project_dir -part $part_name -force

# Set project properties
set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]
set_property default_lib work [current_project]

# Add source files
add_files -norecurse udp_sender.v

# Add constraints file
add_files -fileset constrs_1 -norecurse udp_sender.xdc

# Update compile order
update_compile_order -fileset sources_1

# Set top module
set_property top udp_sender [current_fileset]

# Create IP directory if needed
file mkdir "${project_dir}/${project_name}.srcs/sources_1/ip"

# Optional: Create simulation fileset
# create_fileset -simset sim_1
# add_files -fileset sim_1 -norecurse <simulation_files>

# Update compile order
update_compile_order -fileset sources_1

# Set synthesis and implementation strategies
set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]
set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]

# Set implementation options
set_property steps.phys_opt_design.is_enabled true [get_runs impl_1]

# Save project
save_project

# Print project information
puts "################################################################################"
puts "# Project created successfully!"
puts "# Project Name: $project_name"
puts "# Project Directory: $project_dir"
puts "# Target Part: $part_name"
puts "#"
puts "# Next steps:"
puts "# 1. Review and update pin assignments in udp_sender.xdc"
puts "# 2. Run synthesis: launch_runs synth_1"
puts "# 3. Run implementation: launch_runs impl_1"
puts "# 4. Generate bitstream: launch_runs impl_1 -to_step write_bitstream"
puts "################################################################################"

