# Set the maximum number of threads (e.g., 4)
set_param general.maxThreads 4

# 1. Setup Configuration
set outputDir ./build_output
file mkdir $outputDir

# Define your target part (Change this to your specific FPGA)
#set target_part xcku5p2ffvb676i-1
set target_part xcku5p-ffvb676-2-i
#set_property part xcku5p-ffvb676-1-i [current_project]

# xc7a35tcpg236-1 
set top_module top

# 2. Read Source Files
# Use 'read_vhdl' for VHDL or 'read_verilog' for Verilog
read_verilog [glob ./src/*.v]
read_xdc ./constraints/mapping.xdc

# 3. Run Synthesis
# -top specifies the top-level module name
synth_design -top $top_module -part $target_part
write_checkpoint -force $outputDir/post_synth.dcp

# 4. Run Placement and Optimization
opt_design
place_design
phys_opt_design
write_checkpoint -force $outputDir/post_place.dcp

# 5. Run Routing
route_design
write_checkpoint -force $outputDir/post_route.dcp

# 6. Generate Reports (Crucial for CI logs)
report_timing_summary -file $outputDir/timing_summary.rpt
report_utilization -file $outputDir/utilization.rpt

# 7. Generate Bitstream
write_bitstream -force $outputDir/full_project.bit

puts "Build Completed Successfully!"
