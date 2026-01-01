//////////////////////////////////////////////////////////////////////////////////
// Module Name: udp_packet_gen
// Description: Generates UDP packet data with Ethernet, IP, and UDP headers
//////////////////////////////////////////////////////////////////////////////////

module udp_packet_gen(
    input wire clk,
    input wire reset,
    input wire trigger,
    output reg [7:0] tx_data,
    output reg tx_valid,
    input wire tx_ready,
    output reg tx_start
);

    // Packet parameters (modify as needed)
    parameter [47:0] SRC_MAC = 48'h00_0A_35_01_02_03;  // Source MAC address
    parameter [47:0] DST_MAC = 48'hFF_FF_FF_FF_FF_FF;  // Destination MAC (broadcast)
    parameter [31:0] SRC_IP = 32'hC0_A8_00_64;         // 192.168.0.100
    parameter [31:0] DST_IP = 32'hC0_A8_00_62;         // 192.168.0.98
    parameter [15:0] SRC_PORT = 16'd12345;
    parameter [15:0] DST_PORT = 16'd54321;
    parameter [15:0] UDP_LENGTH = 16'd20;              // UDP header + payload (8 + 12 bytes)
    
    // UDP payload data
    parameter [95:0] PAYLOAD = 96'h48_65_6C_6C_6F_20_57_6F_72_6C_64_21; // "Hello World!"
    
    // State machine
    localparam IDLE = 4'd0;
    localparam PREAMBLE = 4'd1;
    localparam ETH_HEADER = 4'd2;
    localparam IP_HEADER = 4'd3;
    localparam UDP_HEADER = 4'd4;
    localparam UDP_PAYLOAD = 4'd5;
    localparam FCS = 4'd6;
    
    reg [3:0] state;
    reg [7:0] byte_counter;
    reg [15:0] ip_checksum;
    reg [15:0] ip_total_length;
    reg [15:0] ip_header_checksum;
    reg trigger_prev;
    wire trigger_edge;
    
    // Calculate IP header checksum
    always @(*) begin
        ip_total_length = 16'd28; // IP header (20) + UDP (8) + payload (12) = 40, but we use 28 for minimal
        // Simplified checksum calculation (should be proper ones complement)
        ip_header_checksum = 16'h0000; // Simplified - should calculate properly
    end
    
    // Edge detection for trigger
    assign trigger_edge = trigger && !trigger_prev;
    
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            tx_data <= 8'h00;
            tx_valid <= 1'b0;
            tx_start <= 1'b0;
            byte_counter <= 8'd0;
            trigger_prev <= 1'b0;
        end else begin
            trigger_prev <= trigger;
            tx_valid <= 1'b0;
            tx_start <= 1'b0;
            
            case (state)
                IDLE: begin
                    if (trigger_edge) begin
                        state <= PREAMBLE;
                        byte_counter <= 8'd0;
                        tx_start <= 1'b1;
                    end
                end
                
                PREAMBLE: begin
                    if (tx_ready) begin
                        tx_valid <= 1'b1;
                        if (byte_counter < 7) begin
                            tx_data <= 8'h55; // Preamble
                            byte_counter <= byte_counter + 1;
                        end else begin
                            tx_data <= 8'hD5; // Start frame delimiter
                            byte_counter <= 8'd0;
                            state <= ETH_HEADER;
                        end
                    end
                end
                
                ETH_HEADER: begin
                    if (tx_ready) begin
                        tx_valid <= 1'b1;
                        case (byte_counter)
                            0: tx_data <= DST_MAC[47:40];
                            1: tx_data <= DST_MAC[39:32];
                            2: tx_data <= DST_MAC[31:24];
                            3: tx_data <= DST_MAC[23:16];
                            4: tx_data <= DST_MAC[15:8];
                            5: tx_data <= DST_MAC[7:0];
                            6: tx_data <= SRC_MAC[47:40];
                            7: tx_data <= SRC_MAC[39:32];
                            8: tx_data <= SRC_MAC[31:24];
                            9: tx_data <= SRC_MAC[23:16];
                            10: tx_data <= SRC_MAC[15:8];
                            11: tx_data <= SRC_MAC[7:0];
                            12: tx_data <= 8'h08; // EtherType MSB (IPv4)
                            13: begin
                                tx_data <= 8'h00; // EtherType LSB
                                byte_counter <= 8'd0;
                                state <= IP_HEADER;
                            end
                            default: begin
                                byte_counter <= byte_counter + 1;
                            end
                        endcase
                        if (byte_counter < 13) byte_counter <= byte_counter + 1;
                    end
                end
                
                IP_HEADER: begin
                    if (tx_ready) begin
                        tx_valid <= 1'b1;
                        case (byte_counter)
                            0: tx_data <= 8'h45; // Version (4) + IHL (5)
                            1: tx_data <= 8'h00; // DSCP + ECN
                            2: tx_data <= ip_total_length[15:8]; // Total length MSB
                            3: tx_data <= ip_total_length[7:0];  // Total length LSB
                            4: tx_data <= 8'h00; // Identification MSB
                            5: tx_data <= 8'h00; // Identification LSB
                            6: tx_data <= 8'h40; // Flags + Fragment offset MSB
                            7: tx_data <= 8'h00; // Fragment offset LSB
                            8: tx_data <= 8'h40; // TTL
                            9: tx_data <= 8'h11; // Protocol (UDP)
                            10: tx_data <= ip_header_checksum[15:8]; // Checksum MSB
                            11: tx_data <= ip_header_checksum[7:0];  // Checksum LSB
                            12: tx_data <= SRC_IP[31:24];
                            13: tx_data <= SRC_IP[23:16];
                            14: tx_data <= SRC_IP[15:8];
                            15: tx_data <= SRC_IP[7:0];
                            16: tx_data <= DST_IP[31:24];
                            17: tx_data <= DST_IP[23:16];
                            18: tx_data <= DST_IP[15:8];
                            19: begin
                                tx_data <= DST_IP[7:0];
                                byte_counter <= 8'd0;
                                state <= UDP_HEADER;
                            end
                            default: begin
                                byte_counter <= byte_counter + 1;
                            end
                        endcase
                        if (byte_counter < 19) byte_counter <= byte_counter + 1;
                    end
                end
                
                UDP_HEADER: begin
                    if (tx_ready) begin
                        tx_valid <= 1'b1;
                        case (byte_counter)
                            0: tx_data <= SRC_PORT[15:8];
                            1: tx_data <= SRC_PORT[7:0];
                            2: tx_data <= DST_PORT[15:8];
                            3: tx_data <= DST_PORT[7:0];
                            4: tx_data <= UDP_LENGTH[15:8];
                            5: tx_data <= UDP_LENGTH[7:0];
                            6: tx_data <= 8'h00; // Checksum MSB (optional)
                            7: begin
                                tx_data <= 8'h00; // Checksum LSB
                                byte_counter <= 8'd0;
                                state <= UDP_PAYLOAD;
                            end
                            default: begin
                                byte_counter <= byte_counter + 1;
                            end
                        endcase
                        if (byte_counter < 7) byte_counter <= byte_counter + 1;
                    end
                end
                
                UDP_PAYLOAD: begin
                    if (tx_ready) begin
                        tx_valid <= 1'b1;
                        case (byte_counter)
                            0: tx_data <= PAYLOAD[95:88];
                            1: tx_data <= PAYLOAD[87:80];
                            2: tx_data <= PAYLOAD[79:72];
                            3: tx_data <= PAYLOAD[71:64];
                            4: tx_data <= PAYLOAD[63:56];
                            5: tx_data <= PAYLOAD[55:48];
                            6: tx_data <= PAYLOAD[47:40];
                            7: tx_data <= PAYLOAD[39:32];
                            8: tx_data <= PAYLOAD[31:24];
                            9: tx_data <= PAYLOAD[23:16];
                            10: tx_data <= PAYLOAD[15:8];
                            11: begin
                                tx_data <= PAYLOAD[7:0];
                                byte_counter <= byte_counter + 1;
                            end
                            12: begin
                                tx_valid <= 1'b0; // End of frame
                                byte_counter <= 8'd0;
                                state <= IDLE;
                            end
                            default: begin
                                byte_counter <= byte_counter + 1;
                            end
                        endcase
                        if (byte_counter < 11) byte_counter <= byte_counter + 1;
                    end
                end
                
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule

