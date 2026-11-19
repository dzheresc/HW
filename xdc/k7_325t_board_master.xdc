################################################################################
##  Master constraints: xc7k325t board (PCIe Gen2 x4, dual SFP+, 6 LEDs, QSPI)
##
##  Merged from: blinky.xdc, udp_ip_10g_1.xdc (SFP A), udp_ip_10g_2.xdc (SFP B),
##               pcie_7k325_2.xdc. (system_1.xdc is a different board, ignored.)
##
##  Part   : xc7k325t-?ffg676 most likely (pins reach row AF, e.g. C26/AF25).
##           Confirm the speed grade and package with your vendor.
##  Usage  : Each section is independent. Comment out whatever your top level
##           does not have. If a constraint names a port that does not exist,
##           Vivado only warns (CRITICAL WARNING) and skips that line.
##
##  Port naming (rename here or in your top level, but keep them in sync):
##    sys_clk                     100 MHz board oscillator
##    key1                        push button SW1
##    led[5:0]                    user LEDs
##    pcie_perst_n                PCIe PERST# from the edge connector
##    pcie_refclk_p/n             100 MHz PCIe reference clock
##    pci_exp_rxp/rxn/txp/txn[3:0] PCIe lanes (Xilinx IP default names)
##    sfp_refclk_p/n              156.25 MHz SFP+ reference clock (both cages)
##    sfp_a_* / sfp_b_*           SFP+ cage A / cage B
################################################################################


################################################################################
## 1. Board clock: 100 MHz oscillator
################################################################################
set_property PACKAGE_PIN F17      [get_ports sys_clk]
set_property IOSTANDARD  LVCMOS33 [get_ports sys_clk]
# The old PCIe file used -period 41.000 (24.4 MHz). That is wrong for this
# 100 MHz oscillator.
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]


################################################################################
## 2. Push button SW1
################################################################################
# Polarity unknown. Check on hardware or on the schematic.
set_property PACKAGE_PIN C26      [get_ports key1]
set_property IOSTANDARD  LVCMOS33 [get_ports key1]
set_false_path -from [get_ports key1]


################################################################################
## 3. User LEDs
################################################################################
# Silkscreen labels come from the vendor file. led[4] and led[5] were not labelled.
set_property PACKAGE_PIN A19 [get_ports {led[0]}]   ;# LD4 (PCIe demo: debug LED)
set_property PACKAGE_PIN B20 [get_ports {led[1]}]   ;# LD3 (PCIe demo: link_up)
set_property PACKAGE_PIN A20 [get_ports {led[2]}]   ;# LD2
set_property PACKAGE_PIN A17 [get_ports {led[3]}]   ;# LD1
set_property PACKAGE_PIN B17 [get_ports {led[4]}]
set_property PACKAGE_PIN A18 [get_ports {led[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
# LEDs are not timing critical.
set_false_path -to [get_ports {led[*]}]


################################################################################
## 4. PCIe Gen2 x4 (GTX quad X0Y0..X0Y3, hard block PCIE_X0Y0)
################################################################################
# --- PERST# -------------------------------------------------------------------
set_property PACKAGE_PIN E17      [get_ports pcie_perst_n]
set_property IOSTANDARD  LVCMOS33 [get_ports pcie_perst_n]
set_property PULLUP      true     [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]

# --- Reference clock, 100 MHz from the edge connector --------------------------
# Feed it through IBUFDS_GTE2 in your top level (the IP expects that).
set_property PACKAGE_PIN H6 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN H5 [get_ports pcie_refclk_n]
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# --- Lanes ----------------------------------------------------------------------
# Only RXP needs a pin. Vivado places RXN/TXP/TXN on the same GT channel.
# The lane order is REVERSED relative to the GT numbering:
#   lane 0 -> GTXE2_CHANNEL_X0Y3   lane 2 -> GTXE2_CHANNEL_X0Y1
#   lane 1 -> GTXE2_CHANNEL_X0Y2   lane 3 -> GTXE2_CHANNEL_X0Y0
set_property PACKAGE_PIN J4 [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN L4 [get_ports {pci_exp_rxp[1]}]
set_property PACKAGE_PIN N4 [get_ports {pci_exp_rxp[2]}]
set_property PACKAGE_PIN R4 [get_ports {pci_exp_rxp[3]}]

# --- Optional explicit cell LOCs ------------------------------------------------
# The pins above already fix GT placement, and the 7 Series PCIe IP's own XDC
# handles pipe clocks, clock muxes, and async GT status paths. If you still
# get placement errors, uncomment these. They search the hierarchy, so they do
# not depend on your instance names.
#set_property LOC PCIE_X0Y0 [get_cells -hier -filter {REF_NAME == PCIE_2_1}]
#set_property LOC GTXE2_CHANNEL_X0Y3 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL && NAME =~ *pipe_lane[0]*}]
#set_property LOC GTXE2_CHANNEL_X0Y2 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL && NAME =~ *pipe_lane[1]*}]
#set_property LOC GTXE2_CHANNEL_X0Y1 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL && NAME =~ *pipe_lane[2]*}]
#set_property LOC GTXE2_CHANNEL_X0Y0 [get_cells -hier -filter {REF_NAME == GTXE2_CHANNEL && NAME =~ *pipe_lane[3]*}]

# Note: the IP must be configured with "PCIe Block Location" = X0Y0 and the lane
# mapping above. Do not copy the pipe_clock / TXOUTCLK constraints from the old
# GVI file. The IP generates them, and duplicates cause clock-overwrite warnings.


################################################################################
## 5. SFP+ (GTX quad X0Y4..X0Y7)
################################################################################
# Both cages share one 156.25 MHz reference, so a single GTXE2_COMMON (QPLL)
# can drive both 10G channels. Instantiate one IBUFDS_GTE2 and share it.
#
# If your 10G PCS/PMA IP is generated with "shared logic in core", its XDC
# already creates this clock. The line below then just overrides it with the
# same period, which is harmless.

# --- Shared reference clock 156.25 MHz -----------------------------------------
set_property PACKAGE_PIN F6 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN F5 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# --- SFP A (GTXE2_CHANNEL_X0Y7) ---------------------------------------------------
set_property PACKAGE_PIN B6 [get_ports sfp_a_rx_p]
set_property PACKAGE_PIN B5 [get_ports sfp_a_rx_n]
set_property PACKAGE_PIN A4 [get_ports sfp_a_tx_p]
set_property PACKAGE_PIN A3 [get_ports sfp_a_tx_n]
set_property PACKAGE_PIN D14      [get_ports sfp_a_tx_disable]
set_property IOSTANDARD  LVCMOS33 [get_ports sfp_a_tx_disable]
set_false_path -to [get_ports sfp_a_tx_disable]

# --- SFP B (GTXE2_CHANNEL_X0Y6) ---------------------------------------------------
set_property PACKAGE_PIN C4 [get_ports sfp_b_rx_p]
set_property PACKAGE_PIN C3 [get_ports sfp_b_rx_n]
set_property PACKAGE_PIN B2 [get_ports sfp_b_tx_p]
set_property PACKAGE_PIN B1 [get_ports sfp_b_tx_n]
set_property PACKAGE_PIN C14      [get_ports sfp_b_tx_disable]
set_property IOSTANDARD  LVCMOS33 [get_ports sfp_b_tx_disable]
set_false_path -to [get_ports sfp_b_tx_disable]

# --- TODO: SFP sideband pins --------------------------------------------------
# LOS, MOD_ABS (MOD_DEF0), RS0/RS1, TX_FAULT and the I2C (SCL/SDA) lines do not
# appear in any of the vendor files. They may not be routed to the FPGA. Check
# the schematic, or probe them, before adding constraints here.
#set_property PACKAGE_PIN ??? [get_ports sfp_a_los]
#set_property PACKAGE_PIN ??? [get_ports sfp_a_mod_abs]
#set_property PACKAGE_PIN ??? [get_ports sfp_a_scl]
#set_property PACKAGE_PIN ??? [get_ports sfp_a_sda]


################################################################################
## 6. Clock domain crossings
################################################################################
# The three board clocks (sys_clk, pcie_refclk, sfp_refclk) come from
# independent oscillators, so they are asynchronous to each other. Enable this
# only once every crossing between them goes through a proper CDC (async FIFO,
# synchronizer, xpm_cdc_*). It hides ALL paths between the groups.
# GT recovered/TXOUTCLK clocks are created by the IPs and do not appear under
# -include_generated_clocks of the refclk. Add them as extra groups if needed
# (check with: report_clock_interaction).
#
#set_clock_groups -name async_board_clks -asynchronous \
#    -group [get_clocks -include_generated_clocks sys_clk] \
#    -group [get_clocks -include_generated_clocks pcie_refclk] \
#    -group [get_clocks -include_generated_clocks sfp_refclk]
#
# The vendor 10G demo used this form, with clk_wiz_0 driven from sys_clk:
#set_clock_groups -asynchronous \
#    -group [get_clocks -of_objects [get_pins clk_wiz_0/inst/mmcm_adv_inst/CLKOUT0]] \
#    -group [get_clocks sfp_refclk]


################################################################################
## 7. Configuration: QSPI flash (x4, 32-bit addressing)
################################################################################
# QSPI pins (CCLK, D0..D3, FCS_B) are dedicated config pins and need no LOCs.
# To read/write flash from user logic after configuration, use STARTUPE2 for
# CCLK.
#
# CONFIG_VOLTAGE: the vendor files disagree (PCIe file 3.3, 10G files 2.5).
# Every user I/O on this board is LVCMOS33, so bank 0/14 VCCO is most likely 3.3V.
# If write_bitstream reports a CFGBVS/CONFIG_VOLTAGE DRC, or the schematic shows
# VCCO_0 = 2.5V, change this to 2.5.
set_property CFGBVS         VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3  [current_design]

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   4   [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE  YES [current_design]
# 50 MHz is a safe default. The 10G files used 66, which also worked for them.
set_property BITSTREAM.CONFIG.CONFIGRATE     50  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS      TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN      PULLUP [current_design]

# Note on PCIe enumeration: a 325T bitstream (~91 Mbit raw, less compressed)
# over x4 QSPI at 50 MHz (~200 Mbit/s) usually takes longer than the 100 ms
# PCIe allows after power-up. If the host misses the card
# on a cold boot, a warm reboot (or a delayed BIOS PCIe scan) will find it.
