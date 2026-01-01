################################################################################
# Pin Constraints for Artix A7-35 LED Blinker
# Adjust pin numbers based on your specific board configuration
################################################################################

# Clock constraint (adjust pin and frequency based on your board)
# Typical Arty A7-35T uses E3 pin for 100MHz clock
set_property PACKAGE_PIN E3 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name clk [get_ports clk]

# Reset constraint (using a button or switch, adjust pin as needed)
# Typical Arty A7-35T uses C12 pin for reset button
set_property PACKAGE_PIN C12 [get_ports rst]
set_property IOSTANDARD LVCMOS33 [get_ports rst]

# LED constraint (adjust pin based on your board)
# Typical Arty A7-35T uses H5 pin for LD0
set_property PACKAGE_PIN H5 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]

# Additional timing constraints
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets rst_IBUF]

################################################################################
# Note: If using a different Artix A7-35 board variant, adjust pin numbers
# according to your board's schematic
################################################################################

