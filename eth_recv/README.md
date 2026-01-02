# Ethernet Receive to LED Display

This project displays received Ethernet data bits on LEDs using the MII (Media Independent Interface) on the Digilent Arty A7-35 FPGA board.

## Overview

The design captures 4-bit data from the MII Ethernet receive interface (`eth_rxd[3:0]`) and displays it in real-time on the board's LEDs (`led[3:0]`). The LEDs update whenever valid data is received on the Ethernet interface.

## Requirements

### Hardware
- **Board**: Digilent Arty A7-35 (Rev. D or Rev. E)
- **Ethernet PHY**: SMSC Ethernet PHY (onboard)
- **Interface**: MII (Media Independent Interface)

### Software
- **Vivado**: 2017.4 or compatible version
- **Target Part**: xc7a35ticsg324-1L (Arty A7-35)

## Project Structure

```
eth_recv/
├── README.md                    # This file
├── Arty-A7-35-Master.xdc       # Pin constraints file
├── top.v                        # Top-level module
├── eth_led_display.v           # Core Ethernet to LED display module
├── create_project.tcl          # TCL script to create Vivado project
└── build_project.tcl            # TCL script to build project (synthesis/implementation)
```

## Files Description

### `top.v`
Top-level module that:
- Instantiates the Ethernet to LED display module
- Manages Ethernet PHY reset signal (`eth_rstn`)
- Connects all required ports as defined in the XDC constraints

### `eth_led_display.v`
Core module that:
- Captures `eth_rxd[3:0]` on the rising edge of `eth_rx_clk`
- Updates LEDs when `eth_rx_dv` (receive data valid) is asserted
- Holds the last valid data on LEDs when `eth_rx_dv` is deasserted

### `Arty-A7-35-Master.xdc`
Pin constraints file defining:
- LED pin assignments (`led[0]` through `led[3]`)
- MII Ethernet receive interface pins (`eth_rxd[0:3]`, `eth_rx_clk`, `eth_rx_dv`)
- Clock constraints for `eth_rx_clk` (25 MHz, 40 ns period)

### `create_project.tcl`
TCL script for Vivado 2017.4 that:
- Creates a new Vivado project with correct part number
- Adds all source and constraint files
- Sets the top-level module
- Configures project settings

### `build_project.tcl`
TCL script for Vivado 2017.4 that:
- Opens the project
- Runs synthesis
- Runs implementation
- Generates bitstream
- Reports build status

## MII Interface Signals

The MII interface uses the following signals:

| Signal | Direction | Description |
|--------|-----------|-------------|
| `eth_rx_clk` | Input | MII receive clock (25 MHz) |
| `eth_rx_dv` | Input | Receive data valid (indicates valid data on `eth_rxd`) |
| `eth_rxd[3:0]` | Input | 4-bit receive data bus |
| `eth_rstn` | Output | Ethernet PHY reset (active low, kept high) |
| `eth_ref_clk` | Output | Ethernet reference clock |

## How It Works

1. The Ethernet PHY receives data packets on the physical Ethernet interface
2. The PHY converts the data to MII format and presents it on `eth_rxd[3:0]`
3. When valid data is available, `eth_rx_dv` is asserted
4. On each rising edge of `eth_rx_clk`, if `eth_rx_dv` is high, the module captures `eth_rxd[3:0]`
5. The captured data is immediately displayed on `led[3:0]`
6. LEDs hold the last valid data when `eth_rx_dv` is low

## Usage

### Quick Start with TCL Scripts (Recommended)

The easiest way to set up and build the project is using the provided TCL scripts:

#### Method 1: Using Vivado GUI

1. Open Vivado 2017.4
2. In the TCL console, navigate to the project directory:
   ```tcl
   cd <path_to_eth_recv>
   ```
3. Create the project:
   ```tcl
   source create_project.tcl
   ```
4. Build the project (synthesis, implementation, bitstream):
   ```tcl
   source build_project.tcl
   ```
5. Program the FPGA with the generated bitstream from `./eth_recv/eth_recv.runs/impl_1/top.bit`

#### Method 2: Using Command Line (Batch Mode)

1. Open a terminal/command prompt
2. Navigate to the project directory
3. Create and build the project:
   ```bash
   vivado -mode batch -source create_project.tcl
   vivado -mode batch -source build_project.tcl
   ```

### Manual Setup in Vivado

Alternatively, you can set up the project manually:

1. Create a new Vivado project targeting the Arty A7-35 (xc7a35ticsg324-1L)
2. Add the following files to your project:
   - `top.v`
   - `eth_led_display.v`
   - `Arty-A7-35-Master.xdc`
3. Set `top` as the top-level module
4. Run synthesis, implementation, and generate bitstream
5. Program the FPGA with the generated bitstream

### Testing

1. Connect an Ethernet cable to the board's Ethernet port
2. Send Ethernet traffic to the board (e.g., ping, network traffic)
3. Observe the LEDs (`led[0]` through `led[3]`) displaying the received data bits in real-time
4. The LEDs will show the lower 4 bits of each received nibble

## Pin Assignments

### LEDs
- `led[0]`: Package pin H5
- `led[1]`: Package pin J5
- `led[2]`: Package pin T9
- `led[3]`: Package pin T10

### MII Receive Interface
- `eth_rxd[0]`: Package pin D18
- `eth_rxd[1]`: Package pin E17
- `eth_rxd[2]`: Package pin E18
- `eth_rxd[3]`: Package pin G17
- `eth_rx_clk`: Package pin F15 (25 MHz clock)
- `eth_rx_dv`: Package pin G16
- `eth_rstn`: Package pin C16
- `eth_ref_clk`: Package pin G18

## Notes

- The design operates in the `eth_rx_clk` clock domain (25 MHz)
- LEDs display the raw received data bits - this is useful for debugging and monitoring Ethernet traffic
- The Ethernet PHY must be properly configured and initialized (handled by keeping `eth_rstn` high)
- This is a simple demonstration design - for actual Ethernet communication, you would need additional logic to parse Ethernet frames
- The TCL scripts are designed for Vivado 2017.4 but should work with newer versions
- If using a different Vivado version, you may need to adjust the TCL scripts accordingly

## License

This project is provided as-is for educational and demonstration purposes.

