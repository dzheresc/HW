// MII Ethernet Receive to LED Display Module
// Displays received bits from eth_rxd[3:0] to led[3:0]
// Uses MII interface with eth_rx_clk and eth_rx_dv

module eth_led_display (
    // MII Receive Interface
    input wire eth_rx_clk,      // MII receive clock (25 MHz)
    input wire eth_rx_dv,       // MII receive data valid
    input wire [3:0] eth_rxd,   // MII receive data
    
    // LED Outputs
    output reg [3:0] led        // LED outputs to display received data
);

    // Capture and display received data when valid
    always @(posedge eth_rx_clk) begin
        if (eth_rx_dv) begin
            // When data is valid, capture and display on LEDs
            led <= eth_rxd;
        end
        // Note: LEDs will hold the last valid data when eth_rx_dv is low
    end

endmodule

