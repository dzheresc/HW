module top (
    input wire sys_clk_p,
    input wire sys_clk_n,
    output wire [3:0] led    // Output to LED
);

    wire sys_clk_ibuf;
    wire sys_clk;

    IBUFDS #(
      .IBUF_LOW_PWR("FALSE"),
      .IOSTANDARD("DIFF_SSTL12_DCI")  // Added _DCI suffix
    ) u_sys_clk_buf (
      .I(sys_clk_p),
      .IB(sys_clk_n),
      .O(sys_clk_ibuf) // Intermediate wire
    );

    BUFG u_bufg (
        .I(sys_clk_ibuf),
        .O(sys_clk)      // Final clock used in always block
    );

    reg [26:00] counter = 0;

    always @(posedge sys_clk) begin
        counter <= counter + 1;
    end

    assign led = counter[26:23];

endmodule

