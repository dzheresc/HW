//////////////////////////////////////////////////////////////////////////////////
// Module Name: mii_tx
// Description: MII transmit interface - converts byte stream to MII format
//////////////////////////////////////////////////////////////////////////////////

module mii_tx(
    input wire clk,              // 25MHz MII clock
    input wire reset,
    input wire [7:0] tx_data,    // Byte data input
    input wire tx_valid,         // Data valid
    output reg tx_ready,         // Ready for next byte
    input wire tx_start,         // Start of frame
    output reg mii_tx_en,        // MII TX enable
    output reg [3:0] mii_txd     // MII TX data (4 bits)
);

    reg [7:0] data_buffer;
    reg [1:0] nibble_counter;
    reg sending;
    reg tx_valid_prev;
    
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mii_tx_en <= 1'b0;
            mii_txd <= 4'h0;
            data_buffer <= 8'h00;
            nibble_counter <= 2'b00;
            tx_ready <= 1'b0;
            sending <= 1'b0;
            tx_valid_prev <= 1'b0;
        end else begin
            tx_valid_prev <= tx_valid;
            
            if (tx_start && !sending) begin
                sending <= 1'b1;
                nibble_counter <= 2'b00;
                tx_ready <= 1'b1;
            end
            
            if (sending) begin
                if (tx_valid && nibble_counter == 2'b00) begin
                    // Latch new byte
                    data_buffer <= tx_data;
                    nibble_counter <= 2'b01;
                    mii_tx_en <= 1'b1;
                    mii_txd <= tx_data[7:4]; // Upper nibble
                    tx_ready <= 1'b0;
                end else if (nibble_counter == 2'b01) begin
                    // Output lower nibble
                    mii_txd <= data_buffer[3:0];
                    nibble_counter <= 2'b00;
                    
                    // Check if frame is ending
                    if (!tx_valid && tx_valid_prev) begin
                        // Last byte was sent, deassert after this nibble
                        tx_ready <= 1'b0;
                    end else if (!tx_valid) begin
                        // Frame ended, deassert enable
                        mii_tx_en <= 1'b0;
                        sending <= 1'b0;
                        tx_ready <= 1'b0;
                    end else begin
                        tx_ready <= 1'b1;
                    end
                end
            end else begin
                mii_tx_en <= 1'b0;
                mii_txd <= 4'h0;
                tx_ready <= 1'b0;
            end
        end
    end

endmodule

