// Top-level module for Arty A7-35
// Connects MII Ethernet receive data to LEDs

module top (
    // System Clock
    input wire CLK100MHZ,
    
    // MII Ethernet Receive Interface
    input wire eth_rx_clk,      // MII receive clock (25 MHz)
    input wire eth_rx_dv,       // MII receive data valid
    input wire [3:0] eth_rxd,   // MII receive data
    input wire eth_rxerr,       // MII receive error (not used but defined in XDC)
    output wire eth_rstn,       // Ethernet PHY reset (active low)
    output wire eth_ref_clk,    // Ethernet reference clock
    
    // LED Outputs
    output wire [3:0] led       // LED outputs
);

    // Ethernet PHY reset - keep PHY out of reset
    assign eth_rstn = 1'b1;
    
    // Ethernet reference clock - not used for MII but may be needed
    // This would typically come from a clock generator, but for simple display
    // we can leave it unconnected or tie it appropriately
    // assign eth_ref_clk = 1'b0; // Uncomment if needed
    
    // Instantiate the Ethernet to LED display module
    eth_led_display u_eth_led_display (
        .eth_rx_clk(eth_rx_clk),
        .eth_rx_dv(eth_rx_dv),
        .eth_rxd(eth_rxd),
        .led(led)
    );

endmodule

