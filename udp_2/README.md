# UDP Packet Sender for Arty A7-35

This project implements a UDP packet sender using MII (Media Independent Interface) on the Arty A7-35 FPGA development board. The design generates complete Ethernet frames with IP and UDP headers, allowing the FPGA to send UDP packets over Ethernet.

## Overview

The design consists of several Verilog modules that work together to:
- Generate UDP packets with configurable headers
- Build complete Ethernet frames (Ethernet + IP + UDP headers)
- Interface with the Ethernet PHY via MII protocol
- Convert byte-stream data to MII 4-bit format

## Project Structure

```
udp_2/
├── udp_sender_top.v      # Top-level module
├── clk_divider_4x.v       # Clock divider (100MHz → 25MHz)
├── udp_packet_gen.v       # UDP packet generator
├── mii_tx.v              # MII transmit interface
├── create_project.tcl    # Vivado project creation script
├── Arty-A7-35-Master.xdc # Pin constraints file
└── README.md             # This file
```

## Hardware Requirements

- **Board**: Arty A7-35 (Artix-7 FPGA)
- **Ethernet PHY**: SMSC LAN8710A (on-board)
- **Vivado Version**: 2017.4
- **FPGA Part**: xc7a35ticsg324-1L

## Features

- ✅ MII interface for Ethernet transmission
- ✅ Complete UDP packet generation (Ethernet + IP + UDP headers)
- ✅ Configurable MAC addresses, IP addresses, and ports
- ✅ Customizable payload data
- ✅ Edge-triggered packet transmission via button press
- ✅ 25MHz MII clock generation from 100MHz system clock

## Default Configuration

- **Source MAC**: `00:0A:35:01:02:03`
- **Destination MAC**: `FF:FF:FF:FF:FF:FF` (broadcast)
- **Source IP**: `192.168.0.100`
- **Destination IP**: `192.168.0.98`
- **Source Port**: `12345`
- **Destination Port**: `54321`
- **Payload**: `"Hello World!"` (12 bytes)

## Setup Instructions

### 1. Create Vivado Project

Open Vivado 2017.4 and run the TCL script:

```tcl
cd C:/temp/HW/udp_2
source create_project.tcl
```

The project will be created in `./udp_sender/` directory.

### 2. Build the Design

1. Open the project in Vivado
2. Run **Synthesis** (Ctrl+R)
3. Run **Implementation** (Ctrl+I)
4. Generate **Bitstream** (Ctrl+B)

### 3. Program the Device

1. Connect the Arty A7-35 board via USB
2. Open Hardware Manager
3. Auto-detect the device
4. Program the device with the generated bitstream

### 4. Test the Design

1. Connect the board to your network via Ethernet cable
2. Press **Button 0** (btn[0]) to trigger UDP packet transmission
3. Monitor the network using a packet analyzer (Wireshark, etc.)

## Pin Assignments

| Signal | Pin | Description |
|--------|-----|-------------|
| `CLK100MHZ` | E3 | System clock (100MHz) |
| `send_trigger` | D9 | Trigger button (btn[0]) |
| `eth_tx_clk` | H16 | MII TX clock (25MHz) |
| `eth_tx_en` | H15 | MII TX enable |
| `eth_txd[0]` | H14 | MII TX data bit 0 |
| `eth_txd[1]` | J14 | MII TX data bit 1 |
| `eth_txd[2]` | J13 | MII TX data bit 2 |
| `eth_txd[3]` | H17 | MII TX data bit 3 |
| `eth_ref_clk` | G18 | PHY reference clock (25MHz) |

## Customization

To modify packet parameters, edit `udp_packet_gen.v`:

### Change MAC Addresses

```verilog
parameter [47:0] SRC_MAC = 48'h00_0A_35_01_02_03;  // Your source MAC
parameter [47:0] DST_MAC = 48'hFF_FF_FF_FF_FF_FF;  // Your destination MAC
```

### Change IP Addresses

```verilog
parameter [31:0] SRC_IP = 32'hC0_A8_00_64;  // 192.168.0.100
parameter [31:0] DST_IP = 32'hC0_A8_00_62;  // 192.168.0.98
```

### Change UDP Ports

```verilog
parameter [15:0] SRC_PORT = 16'd12345;  // Source port
parameter [15:0] DST_PORT = 16'd54321;  // Destination port
```

### Change Payload

```verilog
// Current: "Hello World!" (12 bytes)
parameter [95:0] PAYLOAD = 96'h48_65_6C_6C_6F_20_57_6F_72_6C_64_21;

// Example: "Test123" (7 bytes, pad with zeros)
parameter [95:0] PAYLOAD = 96'h54_65_73_74_31_32_33_00_00_00_00_00;
```

**Note**: Update `UDP_LENGTH` parameter if payload size changes:
- UDP header: 8 bytes
- Payload: variable
- Total UDP length = 8 + payload_size

## Module Descriptions

### `udp_sender_top.v`
Top-level module that instantiates and connects all sub-modules. Handles clock generation and MII interface connections.

### `clk_divider_4x.v`
Divides the 100MHz system clock by 4 to generate 25MHz clock for MII interface.

### `udp_packet_gen.v`
State machine that generates complete UDP packets:
- Ethernet preamble and SFD
- Ethernet header (MAC addresses, EtherType)
- IP header (version, length, addresses, protocol)
- UDP header (ports, length, checksum)
- UDP payload

### `mii_tx.v`
Converts byte-stream data to MII 4-bit format. Handles:
- Byte-to-nibble conversion
- MII TX enable signal timing
- Frame start/end detection

## Packet Structure

The generated packet follows this structure:

```
[Ethernet Preamble: 7 bytes of 0x55]
[Start Frame Delimiter: 0xD5]
[Ethernet Header: 14 bytes]
  - Destination MAC: 6 bytes
  - Source MAC: 6 bytes
  - EtherType (IPv4): 2 bytes (0x0800)
[IP Header: 20 bytes]
  - Version/IHL: 1 byte (0x45)
  - Total Length: 2 bytes
  - Identification: 2 bytes
  - Flags/Fragment: 2 bytes
  - TTL/Protocol: 2 bytes (TTL=64, Protocol=UDP=0x11)
  - Header Checksum: 2 bytes
  - Source IP: 4 bytes
  - Destination IP: 4 bytes
[UDP Header: 8 bytes]
  - Source Port: 2 bytes
  - Destination Port: 2 bytes
  - Length: 2 bytes
  - Checksum: 2 bytes
[UDP Payload: variable]
```

## Troubleshooting

### No Packets Received

1. **Check Ethernet Connection**: Ensure the board is connected to your network
2. **Verify IP Configuration**: Make sure source/destination IPs are on the same subnet
3. **Check PHY Configuration**: The PHY may need MDIO configuration (not included in this design)
4. **Monitor with Wireshark**: Use a packet analyzer to verify transmission

### Clock Issues

- The clock divider generates 25MHz from 100MHz
- For more precise timing, consider using Vivado Clocking Wizard (MMCM)
- Verify `eth_tx_clk` and `eth_ref_clk` are properly connected

### Synthesis Warnings

- IP header checksum is simplified (set to 0x0000) - may need proper calculation for real networks
- UDP checksum is optional and set to 0x0000

## Limitations

- **No PHY Configuration**: MDIO interface not implemented (PHY may need initialization)
- **Simplified Checksums**: IP and UDP checksums are not properly calculated
- **Fixed Payload Size**: Currently limited to 12 bytes (can be extended)
- **No Receive Path**: Only transmission is implemented
- **No Flow Control**: No backpressure handling

## Future Enhancements

- [ ] Implement proper IP/UDP checksum calculation
- [ ] Add MDIO interface for PHY configuration
- [ ] Support variable payload sizes
- [ ] Add receive path for full UDP communication
- [ ] Implement ARP protocol support
- [ ] Add flow control and error handling

## License

This project is provided as-is for educational and development purposes.

## References

- [Arty A7-35 Reference Manual](https://reference.digilentinc.com/reference/programmable-logic/arty-a7/reference-manual)
- [MII Specification](https://en.wikipedia.org/wiki/Media-Independent_Interface)
- [IEEE 802.3 Ethernet Standard](https://standards.ieee.org/standard/802_3-2018.html)
- [RFC 768 - UDP Protocol](https://tools.ietf.org/html/rfc768)

