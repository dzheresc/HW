# UDP Packet Sender for Artix A7-35

This project implements a UDP packet sender on the Artix A7-35 FPGA board. It sends UDP packets to a specified IP address (192.168.0.98) and port (5555) using the GMII Ethernet interface.

## Overview

The design implements a complete UDP/IP/Ethernet stack in hardware, allowing the FPGA to send UDP packets directly to a target device on the network. The module handles:
- Ethernet frame construction (MAC layer)
- IP packet encapsulation
- UDP datagram formatting
- Checksum calculations
- GMII interface for Ethernet PHY communication

## Project Structure

```
udp/
├── udp_sender.v          # Main Verilog module
├── udp_sender.xdc        # Xilinx constraints file
├── create_project.tcl    # Vivado project creation script
└── README.md             # This file
```

## Requirements

- **Vivado**: Version 2017.4
- **FPGA Board**: Artix A7-35 (xc7a35ticsg324-1L)
- **Ethernet PHY**: GMII-compatible Ethernet PHY chip
- **Clock**: 125 MHz system clock (for GMII interface)

## Target Configuration

- **Target IP Address**: 192.168.0.98
- **Target Port**: 5555
- **Source IP Address**: 192.168.0.100 (configurable in code)
- **Source Port**: 12345 (configurable in code)
- **UDP Payload**: "Hello from Artix A7!" (20 bytes, configurable)

## Quick Start

### 1. Create Vivado Project

Open Vivado 2017.4 and run the TCL script:

```tcl
source create_project.tcl
```

This will create a new project named `udp_sender` with all necessary files.

### 2. Configure Pin Assignments

Edit `udp_sender.xdc` and uncomment/modify the pin assignments according to your board's schematic:

```tcl
# Example pin assignments (adjust for your board):
set_property PACKAGE_PIN W5 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]

set_property PACKAGE_PIN V17 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

# ... add GMII interface pins
```

### 3. Customize Network Parameters

Edit `udp_sender.v` to configure your network settings:

```verilog
parameter TARGET_IP = 32'hC0A80062;      // 192.168.0.98
parameter TARGET_PORT = 16'd5555;        // Port 5555
parameter SOURCE_IP = 32'hC0A80001;      // Your FPGA's IP
parameter SOURCE_PORT = 16'd12345;       // Source port
parameter MAC_DEST = 48'hFFFFFFFFFFFF;   // Broadcast or specific MAC
parameter MAC_SRC = 48'h001122334455;    // Your board's MAC address
```

### 4. Synthesize and Implement

In Vivado:
1. Run synthesis: `launch_runs synth_1`
2. Run implementation: `launch_runs impl_1`
3. Generate bitstream: `launch_runs impl_1 -to_step write_bitstream`

### 5. Program FPGA

Program the generated bitstream to your FPGA board.

## Module Interface

### Ports

| Port Name | Direction | Width | Description |
|-----------|-----------|-------|-------------|
| `clk` | Input | 1 | System clock (125 MHz) |
| `rst_n` | Input | 1 | Active low reset |
| `gmii_txd[7:0]` | Output | 8 | GMII transmit data |
| `gmii_tx_en` | Output | 1 | GMII transmit enable |
| `gmii_tx_er` | Output | 1 | GMII transmit error |
| `gmii_tx_clk` | Output | 1 | GMII transmit clock (125 MHz) |
| `send_packet` | Input | 1 | Trigger to send packet (pulse high) |
| `packet_sent` | Output | 1 | Packet sent acknowledge |
| `packet_count[31:0]` | Output | 32 | Total packets sent counter |

### Usage Example

To send a packet, pulse the `send_packet` signal high for at least one clock cycle. The module will:
1. Construct the complete Ethernet/IP/UDP packet
2. Transmit it via the GMII interface
3. Assert `packet_sent` when transmission is complete
4. Increment `packet_count`

## Packet Structure

The module constructs a complete Ethernet frame:

```
[Ethernet Preamble: 7 bytes of 0x55 + 1 byte 0xD5]
[Ethernet Header: 14 bytes]
  - Destination MAC: 6 bytes
  - Source MAC: 6 bytes
  - EtherType (IPv4): 2 bytes (0x0800)
[IP Header: 20 bytes]
  - Version/IHL/TOS: 2 bytes
  - Total Length: 2 bytes
  - Identification: 2 bytes
  - Flags/Fragment: 2 bytes
  - TTL/Protocol: 2 bytes (TTL=64, Protocol=UDP=17)
  - Header Checksum: 2 bytes
  - Source IP: 4 bytes
  - Destination IP: 4 bytes
[UDP Header: 8 bytes]
  - Source Port: 2 bytes
  - Destination Port: 2 bytes
  - Length: 2 bytes
  - Checksum: 2 bytes
[UDP Data: Variable length]
[FCS: 4 bytes] (typically handled by PHY)
```

## Customizing UDP Payload

Edit the `data_buffer` array in the `initial` block of `udp_sender.v`:

```verilog
initial begin
    data_buffer[0] = 8'h48;  // 'H'
    data_buffer[1] = 8'h65;  // 'e'
    // ... add your data
    data_length = 20;        // Update length
end
```

## Important Notes

1. **MAC Address**: You must set a valid MAC address for your board. Using a broadcast MAC (0xFFFFFFFFFFFF) may not work on all networks.

2. **IP Configuration**: Ensure the source IP address matches your network configuration. The target device must be reachable on the same network.

3. **Clock Domain**: The design assumes a 125 MHz clock for GMII. If your clock is different, adjust the constraints and potentially add clock domain crossing logic.

4. **FCS/CRC**: The current implementation sends zeros for the Frame Check Sequence. Many Ethernet PHYs handle CRC automatically, but verify with your PHY chip documentation.

5. **PHY Interface**: This design uses GMII. If your board uses RGMII, you'll need to modify the interface logic.

6. **Network Configuration**: Ensure your target device (192.168.0.98) is configured to receive UDP packets on port 5555.

## Testing

### On the Target Device

Set up a UDP listener on the target device (192.168.0.98:5555):

**Python example:**
```python
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('0.0.0.0', 5555))

while True:
    data, addr = sock.recvfrom(1024)
    print(f"Received from {addr}: {data.decode()}")
```

**Linux netcat:**
```bash
nc -u -l 5555
```

### Verifying Transmission

- Monitor `packet_sent` signal to confirm packet transmission
- Check `packet_count` to verify multiple packets
- Use a network analyzer (Wireshark) to capture packets on the network

## Troubleshooting

1. **No packets received**: 
   - Verify MAC and IP addresses are correct
   - Check network connectivity
   - Ensure PHY is properly configured and connected

2. **Synthesis errors**:
   - Verify all pin assignments in XDC file
   - Check clock constraints match your clock frequency

3. **Timing violations**:
   - Review timing constraints in XDC file
   - Consider adding pipeline stages if needed

4. **PHY not responding**:
   - Verify GMII interface connections
   - Check PHY configuration and initialization
   - Ensure proper clock domain alignment

## Limitations

- Currently supports fixed payload size (configurable but static)
- No response handling (one-way communication only)
- FCS/CRC may need proper implementation depending on PHY
- No flow control or retry mechanism

## Future Enhancements

Potential improvements:
- Dynamic payload configuration
- UDP receive capability
- ARP protocol support
- ICMP support
- Multiple packet queuing
- Configurable packet rate

## License

This project is provided as-is for educational and development purposes.

## Author

Created for Artix A7-35 FPGA development.

## Version History

- **v1.0** - Initial release
  - Basic UDP packet transmission
  - GMII interface support
  - Fixed target IP and port

