//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/01/01
// Design Name: UDP Sender for Artix A7-35
// Module Name: udp_sender
// Project Name: UDP Packet Sender
// Target Devices: Artix A7-35
// Tool Versions: Vivado 2017.4
// Description: Sends UDP packets to IP 192.168.0.98 port 5555
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module udp_sender (
    // Clock and Reset
    input wire clk,                    // System clock (125 MHz for GMII)
    input wire rst_n,                  // Active low reset
    
    // GMII Interface (Ethernet PHY)
    output reg [7:0] gmii_txd,         // GMII transmit data
    output reg gmii_tx_en,             // GMII transmit enable
    output reg gmii_tx_er,             // GMII transmit error
    output wire gmii_tx_clk,           // GMII transmit clock (125 MHz)
    
    // Control signals
    input wire send_packet,            // Trigger to send packet
    output reg packet_sent,            // Packet sent acknowledge
    
    // Status
    output reg [31:0] packet_count     // Packet counter
);

    // Parameters
    parameter TARGET_IP = 32'hC0A80062;  // 192.168.0.98 in hex
    parameter TARGET_PORT = 16'd5555;       // Port 5555
    parameter SOURCE_IP = 32'hC0A80064;    // 192.168.0.1 (default source)
    parameter SOURCE_PORT = 16'd12345;     // Source port
    parameter MAC_DEST = 48'hFFFFFFFFFFFF; // Broadcast MAC (or specific MAC)
    parameter MAC_SRC = 48'h001122334455;  // Source MAC address
    
    // State machine
    localparam IDLE = 4'd0;
    localparam PREAMBLE = 4'd1;
    localparam ETH_HEADER = 4'd2;
    localparam IP_HEADER = 4'd3;
    localparam UDP_HEADER = 4'd4;
    localparam UDP_DATA = 4'd5;
    localparam FCS = 4'd6;
    localparam DONE = 4'd7;
    
    reg [3:0] state;
    reg [3:0] byte_count;
    reg [15:0] ip_total_length;
    reg [15:0] udp_length;
    reg [15:0] ip_checksum;
    reg [15:0] udp_checksum;
    reg [7:0] data_buffer [0:31];      // Data payload buffer
    reg [4:0] data_length;             // Data length in bytes
    
    // UDP payload data
    initial begin
        data_buffer[0] = 8'h48;  // "Hello from Artix A7!"
        data_buffer[1] = 8'h65;
        data_buffer[2] = 8'h6C;
        data_buffer[3] = 8'h6C;
        data_buffer[4] = 8'h6F;
        data_buffer[5] = 8'h20;
        data_buffer[6] = 8'h66;
        data_buffer[7] = 8'h72;
        data_buffer[8] = 8'h6F;
        data_buffer[9] = 8'h6D;
        data_buffer[10] = 8'h20;
        data_buffer[11] = 8'h41;
        data_buffer[12] = 8'h72;
        data_buffer[13] = 8'h74;
        data_buffer[14] = 8'h69;
        data_buffer[15] = 8'h78;
        data_buffer[16] = 8'h20;
        data_buffer[17] = 8'h41;
        data_buffer[18] = 8'h37;
        data_buffer[19] = 8'h21;
        data_length = 20;
    end
    
    // Clock assignment
    assign gmii_tx_clk = clk;
    
    // Calculate packet lengths
    always @(*) begin
        udp_length = 16'd8 + data_length;  // UDP header (8 bytes) + data
        ip_total_length = 16'd20 + udp_length;  // IP header (20 bytes) + UDP
    end
    
    // IP Header Checksum calculation
    function [15:0] calc_ip_checksum;
        input [15:0] ver_ihl_tos;
        input [15:0] total_length;
        input [15:0] identification;
        input [15:0] flags_fragment;
        input [15:0] ttl_protocol;
        input [15:0] source_ip_high;
        input [15:0] source_ip_low;
        input [15:0] dest_ip_high;
        input [15:0] dest_ip_low;
        reg [31:0] sum;
        begin
            sum = ver_ihl_tos + total_length + identification + flags_fragment +
                  ttl_protocol + source_ip_high + source_ip_low + 
                  dest_ip_high + dest_ip_low;
            while (sum[31:16] != 0)
                sum = sum[31:16] + sum[15:0];
            calc_ip_checksum = ~sum[15:0];
        end
    endfunction
    
    // UDP Checksum calculation (simplified - can be 0 for optional checksum)
    function [15:0] calc_udp_checksum;
        input [15:0] source_ip_high;
        input [15:0] source_ip_low;
        input [15:0] dest_ip_high;
        input [15:0] dest_ip_low;
        input [15:0] protocol;
        input [15:0] udp_length;
        input [15:0] source_port;
        input [15:0] dest_port;
        input [15:0] udp_length_dup;
        reg [31:0] sum;
        begin
            sum = source_ip_high + source_ip_low + dest_ip_high + dest_ip_low +
                  protocol + udp_length + source_port + dest_port + 
                  udp_length_dup;
            while (sum[31:16] != 0)
                sum = sum[31:16] + sum[15:0];
            calc_udp_checksum = ~sum[15:0];
        end
    endfunction
    
    // Main state machine
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            gmii_txd <= 8'h00;
            gmii_tx_en <= 1'b0;
            gmii_tx_er <= 1'b0;
            byte_count <= 4'd0;
            packet_sent <= 1'b0;
            packet_count <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    gmii_tx_en <= 1'b0;
                    gmii_tx_er <= 1'b0;
                    gmii_txd <= 8'h00;
                    byte_count <= 4'd0;
                    packet_sent <= 1'b0;
                    
                    if (send_packet) begin
                        // Pre-calculate checksums
                        ip_checksum <= calc_ip_checksum(
                            16'h4500,           // Version(4) + IHL(5) + TOS(0)
                            ip_total_length,    // Total length
                            16'h0001,           // Identification
                            16'h4000,           // Flags + Fragment offset
                            16'h4011,           // TTL(64) + Protocol(UDP=17)
                            SOURCE_IP[31:16],   // Source IP high
                            SOURCE_IP[15:0],    // Source IP low
                            TARGET_IP[31:16],   // Dest IP high
                            TARGET_IP[15:0]     // Dest IP low
                        );
                        
                        udp_checksum <= calc_udp_checksum(
                            SOURCE_IP[31:16],
                            SOURCE_IP[15:0],
                            TARGET_IP[31:16],
                            TARGET_IP[15:0],
                            16'h0011,           // UDP protocol
                            udp_length,
                            SOURCE_PORT,
                            TARGET_PORT,
                            udp_length
                        );
                        
                        state <= PREAMBLE;
                    end
                end
                
                PREAMBLE: begin
                    gmii_tx_en <= 1'b1;
                    if (byte_count < 7) begin
                        gmii_txd <= 8'h55;  // Preamble bytes
                        byte_count <= byte_count + 1;
                    end else begin
                        gmii_txd <= 8'hD5;  // Start of frame delimiter
                        byte_count <= 4'd0;
                        state <= ETH_HEADER;
                    end
                end
                
                ETH_HEADER: begin
                    case (byte_count)
                        0: gmii_txd <= MAC_DEST[47:40];  // Dest MAC byte 0
                        1: gmii_txd <= MAC_DEST[39:32];  // Dest MAC byte 1
                        2: gmii_txd <= MAC_DEST[31:24];  // Dest MAC byte 2
                        3: gmii_txd <= MAC_DEST[23:16];  // Dest MAC byte 3
                        4: gmii_txd <= MAC_DEST[15:8];   // Dest MAC byte 4
                        5: gmii_txd <= MAC_DEST[7:0];    // Dest MAC byte 5
                        6: gmii_txd <= MAC_SRC[47:40];   // Src MAC byte 0
                        7: gmii_txd <= MAC_SRC[39:32];   // Src MAC byte 1
                        8: gmii_txd <= MAC_SRC[31:24];   // Src MAC byte 2
                        9: gmii_txd <= MAC_SRC[23:16];   // Src MAC byte 3
                        10: gmii_txd <= MAC_SRC[15:8];   // Src MAC byte 4
                        11: gmii_txd <= MAC_SRC[7:0];    // Src MAC byte 5
                        12: gmii_txd <= 8'h08;           // EtherType high (IPv4)
                        13: begin
                            gmii_txd <= 8'h00;           // EtherType low
                            byte_count <= 4'd0;
                            state <= IP_HEADER;
                        end
                        default: begin
                            gmii_txd <= 8'h00;
                            byte_count <= byte_count + 1;
                        end
                    endcase
                end
                
                IP_HEADER: begin
                    case (byte_count)
                        0: gmii_txd <= 8'h45;            // Version(4) + IHL(5)
                        1: gmii_txd <= 8'h00;            // TOS
                        2: gmii_txd <= ip_total_length[15:8];  // Total length high
                        3: gmii_txd <= ip_total_length[7:0];    // Total length low
                        4: gmii_txd <= 8'h00;            // Identification high
                        5: gmii_txd <= 8'h01;            // Identification low
                        6: gmii_txd <= 8'h40;            // Flags + Fragment high
                        7: gmii_txd <= 8'h00;            // Fragment low
                        8: gmii_txd <= 8'h40;            // TTL
                        9: gmii_txd <= 8'h11;            // Protocol (UDP)
                        10: gmii_txd <= ip_checksum[15:8]; // Checksum high
                        11: gmii_txd <= ip_checksum[7:0];  // Checksum low
                        12: gmii_txd <= SOURCE_IP[31:24]; // Source IP byte 0
                        13: gmii_txd <= SOURCE_IP[23:16]; // Source IP byte 1
                        14: gmii_txd <= SOURCE_IP[15:8];  // Source IP byte 2
                        15: gmii_txd <= SOURCE_IP[7:0];   // Source IP byte 3
                        16: gmii_txd <= TARGET_IP[31:24]; // Dest IP byte 0
                        17: gmii_txd <= TARGET_IP[23:16]; // Dest IP byte 1
                        18: gmii_txd <= TARGET_IP[15:8];  // Dest IP byte 2
                        19: begin
                            gmii_txd <= TARGET_IP[7:0];   // Dest IP byte 3
                            byte_count <= 4'd0;
                            state <= UDP_HEADER;
                        end
                        default: begin
                            gmii_txd <= 8'h00;
                            byte_count <= byte_count + 1;
                        end
                    endcase
                end
                
                UDP_HEADER: begin
                    case (byte_count)
                        0: gmii_txd <= SOURCE_PORT[15:8]; // Source port high
                        1: gmii_txd <= SOURCE_PORT[7:0];  // Source port low
                        2: gmii_txd <= TARGET_PORT[15:8]; // Dest port high
                        3: gmii_txd <= TARGET_PORT[7:0];  // Dest port low
                        4: gmii_txd <= udp_length[15:8];  // Length high
                        5: gmii_txd <= udp_length[7:0];   // Length low
                        6: gmii_txd <= udp_checksum[15:8]; // Checksum high
                        7: begin
                            gmii_txd <= udp_checksum[7:0];  // Checksum low
                            byte_count <= 4'd0;
                            if (data_length > 0)
                                state <= UDP_DATA;
                            else
                                state <= FCS;
                        end
                        default: begin
                            gmii_txd <= 8'h00;
                            byte_count <= byte_count + 1;
                        end
                    endcase
                end
                
                UDP_DATA: begin
                    if (byte_count < data_length) begin
                        gmii_txd <= data_buffer[byte_count];
                        byte_count <= byte_count + 1;
                    end else begin
                        byte_count <= 4'd0;
                        state <= FCS;
                    end
                end
                
                FCS: begin
                    // FCS is typically handled by PHY, but we send 4 bytes of zeros
                    // In real implementation, CRC32 should be calculated
                    if (byte_count < 4) begin
                        gmii_txd <= 8'h00;
                        byte_count <= byte_count + 1;
                    end else begin
                        gmii_tx_en <= 1'b0;
                        gmii_txd <= 8'h00;
                        state <= DONE;
                    end
                end
                
                DONE: begin
                    packet_count <= packet_count + 1;
                    packet_sent <= 1'b1;
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule

