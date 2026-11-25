// Drop-in replacement for the MIG example design's example_tb: runs ddr_memtest
// (write + read/verify passes) on the real MIG RTL and DDR4 models, then reports.
// Used by sim/mig/run_mig_sim.tcl.
`timescale 1ps/1ps
module example_tb #(
  parameter SIMULATION = "FALSE", parameter APP_DATA_WIDTH = 256, parameter APP_ADDR_WIDTH = 29,
  parameter nCK_PER_CLK = 4, parameter MEM_ADDR_ORDER = "ROW_COLUMN_BANK"
) (
  input clk, input rst, input init_calib_complete, input app_rdy, input app_wdf_rdy,
  input app_rd_data_valid, input [APP_DATA_WIDTH-1:0] app_rd_data,
  output [2:0] app_cmd, output [APP_ADDR_WIDTH-1:0] app_addr, output app_en,
  output [(APP_DATA_WIDTH/8)-1:0] app_wdf_mask, output [APP_DATA_WIDTH-1:0] app_wdf_data,
  output app_wdf_end, output app_wdf_wren, output compare_error, output wr_rd_complete
);
  reg start = 0;  reg [1:0] mode = 2'd0;
  wire sel, busy, wren;
  wire [31:0] errs, wcyc, rcyc, eaddr, eexp, egot;
  ddr_memtest #(.AW(26)) mt (
    .clk(clk), .rst(rst), .start(start), .cfg_base(26'h100), .cfg_len(27'd512), .cfg_wr(1'b1), .cfg_rd(1'b1),
    .cfg_mode(mode), .cfg_seed(32'h5EED0000), .br_idle(1'b1),
    .sel(sel), .app_en(app_en), .app_cmd(app_cmd), .app_addr(app_addr), .app_wren(wren), .app_wdata(app_wdf_data),
    .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy), .rd_valid(app_rd_data_valid), .rd_data(app_rd_data),
    .busy(busy), .xst_errs(errs), .xst_wcyc(wcyc), .xst_rcyc(rcyc), .xst_err_addr(eaddr), .xst_err_exp(eexp), .xst_err_got(egot));
  assign app_wdf_wren = wren;
  assign app_wdf_end = wren;
  assign app_wdf_mask = 0;
  assign compare_error = 1'b0;
  assign wr_rd_complete = 1'b0;
  integer i;
  initial begin
    wait (init_calib_complete === 1'b1);
    $display("%t MT: calibration done", $time);
    for (i = 0; i < 3; i = i + 1) begin
      repeat (50) @(posedge clk);
      mode = i;
      @(posedge clk) start <= 1;  @(posedge clk) start <= 0;
      @(posedge clk); wait (!busy);
      $display("%t MT mode %0d: errs %0d wcyc %0d rcyc %0d first err addr %h exp %h got %h",
               $time, i, errs, wcyc, rcyc, eaddr, eexp, egot);
    end
    $display("MT DONE");
    $finish;
  end
  // log the first few read words
  integer nrd = 0;
  always @(posedge clk) if (app_rd_data_valid && sel && nrd < 4) begin
    $display("%t MT rd %0d: %h", $time, nrd, app_rd_data); nrd = nrd + 1;
  end
endmodule
