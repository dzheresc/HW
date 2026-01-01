################################################################################
# Constraints file for UDP Sender on Artix A7-35
# Target Device: xc7a35ticsg324-1L (Artix-7 35T in CSG324 package)
# Tool Version: Vivado 2017.4
################################################################################

################################################################################
# Clock Constraints
################################################################################

# System clock - 125 MHz for GMII interface
# Adjust pin assignment based on your board's clock source
create_clock -period 8.000 -name clk [get_ports clk]

# GMII TX Clock - typically same as system clock for GMII
# If using RGMII, this would be 125 MHz with 90 degree phase shift

################################################################################
# Timing Constraints
################################################################################

# Input delay for control signals
set_input_delay -clock clk -max 2.0 [get_ports send_packet]
set_input_delay -clock clk -min 0.5 [get_ports send_packet]

# Output delay for GMII signals
set_output_delay -clock clk -max 2.0 [get_ports {gmii_txd[*] gmii_tx_en gmii_tx_er}]
set_output_delay -clock clk -min 0.5 [get_ports {gmii_txd[*] gmii_tx_en gmii_tx_er}]

################################################################################
# Pin Assignments - Example for common Artix A7-35 boards
# NOTE: Adjust these pin assignments based on your specific board
################################################################################

# Clock input (example - adjust to your board)
# set_property PACKAGE_PIN W5 [get_ports clk]
# set_property IOSTANDARD LVCMOS33 [get_ports clk]

# Reset (active low)
# set_property PACKAGE_PIN V17 [get_ports rst_n]
# set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

# Control signals
# set_property PACKAGE_PIN U16 [get_ports send_packet]
# set_property IOSTANDARD LVCMOS33 [get_ports send_packet]

# Status outputs
# set_property PACKAGE_PIN V16 [get_ports packet_sent]
# set_property IOSTANDARD LVCMOS33 [get_ports packet_sent]
# set_property PACKAGE_PIN T17 [get_ports {packet_count[0]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {packet_count[0]}]

################################################################################
# GMII Interface Pin Assignments
# These are example assignments - MUST be adjusted for your specific board
################################################################################

# GMII Transmit Data [7:0]
# set_property PACKAGE_PIN T18 [get_ports {gmii_txd[0]}]
# set_property PACKAGE_PIN W18 [get_ports {gmii_txd[1]}]
# set_property PACKAGE_PIN U18 [get_ports {gmii_txd[2]}]
# set_property PACKAGE_PIN T19 [get_ports {gmii_txd[3]}]
# set_property PACKAGE_PIN R18 [get_ports {gmii_txd[4]}]
# set_property PACKAGE_PIN P18 [get_ports {gmii_txd[5]}]
# set_property PACKAGE_PIN U19 [get_ports {gmii_txd[6]}]
# set_property PACKAGE_PIN R19 [get_ports {gmii_txd[7]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {gmii_txd[*]}]

# GMII Transmit Enable
# set_property PACKAGE_PIN P19 [get_ports gmii_tx_en]
# set_property IOSTANDARD LVCMOS33 [get_ports gmii_tx_en]

# GMII Transmit Error
# set_property PACKAGE_PIN N19 [get_ports gmii_tx_er]
# set_property IOSTANDARD LVCMOS33 [get_ports gmii_tx_er]

# GMII Transmit Clock (125 MHz)
# set_property PACKAGE_PIN M19 [get_ports gmii_tx_clk]
# set_property IOSTANDARD LVCMOS33 [get_ports gmii_tx_clk]

################################################################################
# Configuration Constraints
################################################################################

# Configuration mode
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

################################################################################
# Timing Exceptions (if needed)
################################################################################

# False paths for asynchronous signals
# set_false_path -from [get_ports rst_n]

################################################################################
# Power and Optimization Constraints
################################################################################

# Power optimization
set_property POWER_OPT_ENABLED TRUE [current_design]

# Keep hierarchy (useful for debugging)
# set_property KEEP_HIERARCHY TRUE [get_cells udp_sender]

################################################################################
# Additional Notes:
# 1. Uncomment and adjust pin assignments based on your specific board
# 2. For GMII interface, ensure proper clock domain crossing if needed
# 3. Verify IOSTANDARD matches your board's voltage levels (LVCMOS33, LVCMOS25, etc.)
# 4. If using RGMII instead of GMII, additional constraints for clock phase are needed
# 5. Adjust clock period based on your actual clock frequency
################################################################################

