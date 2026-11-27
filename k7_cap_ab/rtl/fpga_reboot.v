// Reboot the FPGA from its configuration flash (IPROG through the ICAP),
// without the host: a one-cycle `go` pulse in the clk domain starts it.
//
// FAMILY = "USP" uses ICAPE3 (UltraScale+), "7S" uses ICAPE2 (7 Series).
// icap_clk: any free-running clock within the ICAP limit (UG570/UG470), e.g.
// STARTUPE2/E3 CFGMCLK (~65 / ~50 MHz) through a BUFG.
//
// Sequence (UG570 "IPROG Using ICAPE3", UG470 "IPROG Reconfiguration"):
//   FFFFFFFF dummy, AA995566 sync, 20000000 NOOP,
//   30020001 write WBSTAR, 00000000 (boot address 0),
//   30008001 write CMD, 0000000F IPROG, 20000000 NOOP
// ICAP data is bit-swapped within each byte.
`default_nettype none
module fpga_reboot #(
  parameter FAMILY = "USP",
  parameter [31:0] WBSTAR = 32'h0000_0000
) (
  input  wire clk,
  input  wire go,
  input  wire icap_clk,
  output wire busy          // clk domain: reboot requested (the device goes away)
);
  // clk -> icap_clk: toggle synchronizer, sticky (a reboot is never undone)
  reg req = 1'b0;
  always @(posedge clk) if (go) req <= 1'b1;
  assign busy = req;

  (* ASYNC_REG = "TRUE" *) reg [2:0] req_s = 3'b000;
  always @(posedge icap_clk) req_s <= {req_s[1:0], req};

  function [31:0] bswap(input [31:0] w);
    integer b, i;
    begin
      for (b = 0; b < 4; b = b + 1)
        for (i = 0; i < 8; i = i + 1)
          bswap[8 * b + i] = w[8 * b + 7 - i];
    end
  endfunction

  reg [3:0]  n = 4'd0;
  reg        csib = 1'b1;
  reg [31:0] data = 32'hFFFF_FFFF;
  reg [31:0] word;
  always @* begin
    case (n)
      4'd0: word = 32'hFFFF_FFFF;
      4'd1: word = 32'hAA99_5566;
      4'd2: word = 32'h2000_0000;
      4'd3: word = 32'h3002_0001;
      4'd4: word = WBSTAR;
      4'd5: word = 32'h3000_8001;
      4'd6: word = 32'h0000_000F;
      default: word = 32'h2000_0000;
    endcase
  end
  always @(posedge icap_clk) begin
    if (req_s[2] && n != 4'd9) begin
      data <= bswap(word);
      csib <= (n == 4'd8);     // 8 words with CSIB low, then release
      n    <= n + 4'd1;
    end
  end

  generate if (FAMILY == "USP") begin : g_usp
    ICAPE3 #(.ICAP_AUTO_SWITCH("DISABLE"), .SIM_CFG_FILE_NAME("NONE")) icap (
      .AVAIL(), .O(), .PRDONE(), .PRERROR(),
      .CLK(icap_clk), .CSIB(csib), .I(data), .RDWRB(1'b0));
  end else begin : g_7s
    ICAPE2 #(.ICAP_WIDTH("X32"), .SIM_CFG_FILE_NAME("NONE")) icap (
      .O(), .CLK(icap_clk), .CSIB(csib), .I(data), .RDWRB(1'b0));
  end endgenerate
endmodule
`default_nettype wire
