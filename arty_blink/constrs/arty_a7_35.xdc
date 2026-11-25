## Digilent Arty A7-35T (xc7a35ticsg324-1L) - blink
## Pin names taken from Digilent Arty-A7-35-Master.xdc

## 100 MHz oscillator
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk_pin -period 10.000 -waveform {0 5} [get_ports { clk }]

## RESET push button (ck_rst, active low, pulled up on board)
set_property -dict { PACKAGE_PIN C2  IOSTANDARD LVCMOS33 } [get_ports { rst_n }]

## Green LEDs LD4..LD7
set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Timing exceptions: asynchronous button in, slow LEDs out
set_false_path -from [get_ports { rst_n }]
set_false_path -to   [get_ports { led[*] }]

## Configuration: bank 0 at 3.3 V, quad-SPI flash boot
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
