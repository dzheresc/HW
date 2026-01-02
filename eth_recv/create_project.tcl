# Vivado 2017.4 TCL Script
# Creates a new project for Arty A7-35 Ethernet Receive to LED Display
#
# Usage: In Vivado TCL console, run:
#   source create_project.tcl
#
# Or from command line:
#   vivado -mode batch -source create_project.tcl

# Close any existing project
close_project -quiet

# Create project
set project_name "eth_recv"
set project_dir "./${project_name}"

# Create project in current directory
create_project ${project_name} ${project_dir} -part xc7a35ticsg324-1L -force

# Set project properties
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# Add source files
add_files -fileset sources_1 {
    top.v
    eth_led_display.v
    clk_divider.v
}

# Add constraint files
add_files -fileset constrs_1 {
    Arty-A7-35-Master.xdc
}

# Set top module
set_property top top [current_fileset]

# Update compile order
update_compile_order -fileset sources_1

# Set constraint file target
set_property target_constrs_file Arty-A7-35-Master.xdc [current_fileset -constrset]

# Save project
save_project_as eth_recv

# Print project information
puts "Project created successfully!"
puts "Project name: ${project_name}"
puts "Project directory: ${project_dir}"
puts "Target part: xc7a35ticsg324-1L (Arty A7-35)"
puts ""
puts "To run synthesis:"
puts "  launch_runs synth_1"
puts ""
puts "To run implementation:"
puts "  launch_runs impl_1 -to_step write_bitstream"
puts ""
puts "To open the project later:"
puts "  open_project ${project_dir}/${project_name}.xpr"

