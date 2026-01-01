################################################################################
# TCL Script for Vivado 2017.4
# Creates a project for Artix A7-35 LED Blinker
################################################################################

# Set project variables
set project_name "led_blinker"
set project_dir "./${project_name}"
set part_name "xc7a35ticsg324-1L";  # Artix A7-35T in CSG324 package

# Create project directory if it doesn't exist
file mkdir $project_dir

# Create project
create_project $project_name $project_dir -part $part_name -force

# Set project properties
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# Add source files
add_files -fileset sources_1 [glob *.v]
update_compile_order -fileset sources_1

# Add constraint files
add_files -fileset constrs_1 [glob *.xdc]
update_compile_order -fileset constrs_1

# Set top module
set_property top led_blinker [current_fileset]

# Update compile order
update_compile_order -fileset sources_1

# Launch synthesis (optional - comment out if you want to run manually)
# launch_runs synth_1 -jobs 4
# wait_on_run synth_1

# Launch implementation (optional - comment out if you want to run manually)
# launch_runs impl_1 -jobs 4
# wait_on_run impl_1

# Generate bitstream (optional - comment out if you want to run manually)
# launch_runs impl_1 -to_step write_bitstream -jobs 4
# wait_on_run impl_1

puts "Project created successfully!"
puts "Project location: [file normalize $project_dir]"
puts ""
puts "To run synthesis and implementation:"
puts "  launch_runs synth_1"
puts "  wait_on_run synth_1"
puts "  launch_runs impl_1"
puts "  wait_on_run impl_1"
puts "  launch_runs impl_1 -to_step write_bitstream"

