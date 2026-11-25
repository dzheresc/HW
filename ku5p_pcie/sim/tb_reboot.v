// fpga_reboot with a behavioural ICAPE3 stub: checks the IPROG word sequence.
`timescale 1ns/1ps
module ICAPE3 #(parameter ICAP_AUTO_SWITCH = "DISABLE", parameter SIM_CFG_FILE_NAME = "NONE") (
  output AVAIL, output [31:0] O, output PRDONE, output PRERROR,
  input CLK, input CSIB, input [31:0] I, input RDWRB);
  reg [31:0] got [0:15]; integer n = 0, b, i; reg [31:0] w;
  always @(posedge CLK) if (!CSIB && !RDWRB) begin
    for (b = 0; b < 4; b = b + 1) for (i = 0; i < 8; i = i + 1) w[8*b+i] = I[8*b+7-i];
    got[n] = w; n = n + 1;
  end
endmodule
module tb_reboot;
  reg clk = 0, iclk = 0, go = 0;
  always #2 clk = ~clk;
  always #10 iclk = ~iclk;
  fpga_reboot #(.FAMILY("USP")) dut (.clk(clk), .go(go), .icap_clk(iclk), .busy());
  reg [31:0] want [0:7]; integer k, err = 0;
  initial begin
    want[0]=32'hFFFFFFFF; want[1]=32'hAA995566; want[2]=32'h20000000; want[3]=32'h30020001;
    want[4]=32'h00000000; want[5]=32'h30008001; want[6]=32'h0000000F; want[7]=32'h20000000;
    #200; @(posedge clk) go <= 1; @(posedge clk) go <= 0;
    #2000;
    if (dut.g_usp.icap.n != 8) begin $display("FAIL: %0d words", dut.g_usp.icap.n); err = 1; end
    for (k = 0; k < 8; k = k + 1) if (dut.g_usp.icap.got[k] !== want[k]) begin
      $display("FAIL word %0d: %08x want %08x", k, dut.g_usp.icap.got[k], want[k]); err = 1; end
    if (!err) $display("PASS reboot sequence (8 words, CSIB released)");
    $finish;
  end
endmodule
