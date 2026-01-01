//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/01/01
// Design Name: UDP Packet Sender
// Module Name: udp_sender_top
// Project Name: UDP Sender
// Target Devices: Arty A7-35
// Tool Versions: Vivado 2017.4
// Description: Top-level module for sending UDP packets over MII interface
// 
//////////////////////////////////////////////////////////////////////////////////

module udp_sender_top(
    input wire CLK100MHZ,
    
    // MII TX Interface
    output wire eth_tx_clk,
    output wire eth_tx_en,
    output wire [3:0] eth_txd,
    output wire eth_ref_clk,
    
    // Control signals (can be connected to buttons/switches)
    input wire send_trigger
);

    // Internal signals
    wire clk_25mhz;
    wire clk_locked;
    wire [7:0] tx_data;
    wire tx_valid;
    wire tx_ready;
    wire tx_start;
    
    // Clock divider: 100MHz -> 25MHz for MII
    clk_divider_4x u_clk_div (
        .clk_in(CLK100MHZ),
        .clk_out(clk_25mhz),
        .reset(1'b0)
    );
    
    // Assign MII TX clock
    assign eth_tx_clk = clk_25mhz;
    
    // Generate 25MHz reference clock for PHY
    assign eth_ref_clk = clk_25mhz;
    
    // UDP packet generator
    udp_packet_gen u_udp_gen (
        .clk(clk_25mhz),
        .reset(1'b0),
        .trigger(send_trigger),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_start(tx_start)
    );
    
    // MII TX interface
    mii_tx u_mii_tx (
        .clk(clk_25mhz),
        .reset(1'b0),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_start(tx_start),
        .mii_tx_en(eth_tx_en),
        .mii_txd(eth_txd)
    );

endmodule

