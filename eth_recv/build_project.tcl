# Vivado 2017.4 TCL Script
# Builds the Ethernet Receive to LED Display project
# Runs synthesis, implementation, and generates bitstream
#
# Usage: In Vivado TCL console, run:
#   source build_project.tcl
#
# Or from command line:
#   vivado -mode batch -source build_project.tcl

set project_name "eth_recv"
set project_dir "./${project_name}"

# Open project if it exists, otherwise create it
if {[file exists "${project_dir}/${project_name}.xpr"]} {
    open_project "${project_dir}/${project_name}.xpr"
    puts "Opened existing project: ${project_name}"
} else {
    puts "Project not found. Please run create_project.tcl first."
    exit
}

# Set top module
set_property top top [current_fileset]

# Update compile order
update_compile_order -fileset sources_1

# Run synthesis
puts "Starting synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit
} else {
    puts "Synthesis completed successfully!"
}

# Run implementation
puts "Starting implementation..."
reset_run impl_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit
} else {
    puts "Implementation completed successfully!"
}

# Generate bitstream
puts "Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Bitstream generation failed!"
    exit
} else {
    puts "Bitstream generated successfully!"
    puts ""
    puts "Bitstream location:"
    puts "[get_property DIRECTORY [get_runs impl_1]]/${project_name}.bit"
}

puts ""
puts "Build completed successfully!"

