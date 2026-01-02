// Top-level module for Arty A7-35
// Connects MII Ethernet receive data to LEDs

module top (
    // System Clock
    input wire CLK100MHZ,
    
    // MII Ethernet Receive Interface
    input wire eth_rx_clk,      // MII receive clock (25 MHz)
    input wire eth_rx_dv,       // MII receive data valid
    input wire [3:0] eth_rxd,   // MII receive data
 //   input wire eth_rxerr,       // MII receive error (not used but defined in XDC)
    output wire eth_rstn,       // Ethernet PHY reset (active low)
    output wire eth_ref_clk,    // Ethernet reference clock
    
    // LED Outputs
    output wire [3:0] led       // LED outputs
);

    // Ethernet PHY reset - keep PHY out of reset
    assign eth_rstn = 1'b1;
    
    // Clock divider to generate 25 MHz for eth_ref_clk from 100 MHz system clock
    clk_divider u_clk_divider (
        .clk_in(CLK100MHZ),
        .rst(1'b0),              // No reset needed
        .clk_out(eth_ref_clk)    // 25 MHz output
    );
    
    // Instantiate the Ethernet to LED display module
    eth_led_display u_eth_led_display (
        .eth_rx_clk(eth_rx_clk),
        .eth_rx_dv(eth_rx_dv),
        .eth_rxd(eth_rxd),
        .led(led)
    );

endmodule

