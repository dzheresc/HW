// Clock-domain bridge between a simple user-clock DDR port and the MIG DDR4
// native application interface (ui_clk), plus a takeover port for the
// in-fabric memory test, which drives the MIG directly at full ui_clk rate.
//
// User side (uclk), one 256-bit DDR word (32 bytes, one BL8 on the 32-bit bus)
// per command:
//   c_valid/c_ready  command, c_we = write, c_addr = 32-byte word index, c_wdata
//   r_valid/r_pop    read data, returned in command order (FWFT: r_data is valid
//                    while r_valid; r_pop takes it)
// Commands go through an async FIFO; reads are only issued to the MIG while the
// read-data FIFO is guaranteed to have room, so the MIG never overruns it.
//
// mt_sel hands the MIG to the memory test. It must only be raised while br_idle
// (nothing queued or in flight here), and dropped only after all of the memory
// test's reads have returned.
`default_nettype none
module ddr_bridge #(
  parameter AW = 26                  // word address bits (2 GB / 32 B = 2^26)
) (
  input  wire           uclk,
  input  wire           urst,        // uclk domain, also resets on ui_rst
  input  wire           c_valid,
  output wire           c_ready,
  input  wire           c_we,
  input  wire [AW-1:0]  c_addr,
  input  wire [255:0]   c_wdata,
  output wire           r_valid,
  output wire [255:0]   r_data,
  input  wire           r_pop,

  input  wire           ui_clk,
  input  wire           ui_rst,
  output reg            br_idle,     // ui_clk domain
  input  wire           mt_sel,
  input  wire           mt_en,
  input  wire [2:0]     mt_cmd,
  input  wire [28:0]    mt_addr,
  input  wire           mt_wren,
  input  wire [255:0]   mt_wdata,

  output wire           app_en,
  output wire [2:0]     app_cmd,
  output wire [28:0]    app_addr,
  output wire           app_wdf_wren,
  output wire           app_wdf_end,
  output wire [255:0]   app_wdf_data,
  output wire [31:0]    app_wdf_mask,
  input  wire           app_rdy,
  input  wire           app_wdf_rdy,
  input  wire           app_rd_data_valid,
  input  wire [255:0]   app_rd_data
);
  localparam CW = 1 + AW + 256;
  localparam DEPTH = 512;

  // ---------------- command FIFO (uclk -> ui_clk) ----------------
  wire          cq_full, cq_wbusy, cq_empty, cq_rbusy;
  wire [CW-1:0] cq_dout;
  wire          cq_pop;
  assign c_ready = ~cq_full & ~cq_wbusy;

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("block"), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
    .FIFO_WRITE_DEPTH(DEPTH), .WRITE_DATA_WIDTH(CW), .WR_DATA_COUNT_WIDTH(10),
    .PROG_FULL_THRESH(DEPTH - 8), .FULL_RESET_VALUE(1), .USE_ADV_FEATURES("0000"),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .READ_DATA_WIDTH(CW),
    .RD_DATA_COUNT_WIDTH(10), .PROG_EMPTY_THRESH(8), .DOUT_RESET_VALUE("0"),
    .CDC_SYNC_STAGES(3), .WAKEUP_TIME(0)
  ) cmdq (
    .sleep(1'b0), .rst(urst),
    .wr_clk(uclk), .wr_en(c_valid & c_ready), .din({c_we, c_addr, c_wdata}),
    .full(cq_full), .prog_full(), .wr_data_count(), .overflow(), .wr_rst_busy(cq_wbusy),
    .almost_full(), .wr_ack(),
    .rd_clk(ui_clk), .rd_en(cq_pop), .dout(cq_dout), .empty(cq_empty), .prog_empty(),
    .rd_data_count(), .underflow(), .rd_rst_busy(cq_rbusy), .almost_empty(), .data_valid(),
    .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr()
  );

  // ---------------- read-data FIFO (ui_clk -> uclk) ----------------
  wire       rq_wbusy, rq_empty;
  wire [9:0] rq_cnt;
  reg        rd_v_q = 1'b0;
  reg [255:0] rd_d_q;
  always @(posedge ui_clk) begin
    rd_v_q <= app_rd_data_valid & ~mt_sel;
    rd_d_q <= app_rd_data;
  end

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("block"), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
    .FIFO_WRITE_DEPTH(DEPTH), .WRITE_DATA_WIDTH(256), .WR_DATA_COUNT_WIDTH(10),
    .PROG_FULL_THRESH(DEPTH - 8), .FULL_RESET_VALUE(1), .USE_ADV_FEATURES("0004"),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .READ_DATA_WIDTH(256),
    .RD_DATA_COUNT_WIDTH(10), .PROG_EMPTY_THRESH(8), .DOUT_RESET_VALUE("0"),
    .CDC_SYNC_STAGES(3), .WAKEUP_TIME(0)
  ) rdq (
    .sleep(1'b0), .rst(ui_rst),
    .wr_clk(ui_clk), .wr_en(rd_v_q), .din(rd_d_q),
    .full(), .prog_full(), .wr_data_count(rq_cnt), .overflow(), .wr_rst_busy(rq_wbusy),
    .almost_full(), .wr_ack(),
    .rd_clk(uclk), .rd_en(r_pop & r_valid), .dout(r_data), .empty(rq_empty), .prog_empty(),
    .rd_data_count(), .underflow(), .rd_rst_busy(), .almost_empty(), .data_valid(),
    .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr()
  );
  assign r_valid = ~rq_empty;

  // ---------------- issue to the MIG (ui_clk) ----------------
  // rd_out: reads issued whose data has not reached the read FIFO yet.
  // wr_data_count lags reads on the other side, so it over-estimates the
  // occupancy: the credit check is conservative.
  reg  [9:0] rd_out = 10'd0;
  reg        credit_ok = 1'b0;
  wire       q_we   = cq_dout[CW-1];
  wire [AW-1:0] q_addr = cq_dout[256 +: AW];
  wire       q_ok   = ~cq_empty & ~cq_rbusy & ~mt_sel;
  wire       can    = q_ok & (q_we ? app_wdf_rdy : credit_ok);
  assign cq_pop = can & app_rdy;
  wire       rd_issue = cq_pop & ~q_we;

  always @(posedge ui_clk) begin
    if (ui_rst) begin
      rd_out <= 10'd0;
      credit_ok <= 1'b0;
      br_idle <= 1'b0;
    end else begin
      rd_out <= rd_out + {9'd0, rd_issue} - {9'd0, rd_v_q};
      // leave margin for the reads that can be issued while this is registered
      credit_ok <= ({1'b0, rd_out} + {1'b0, rq_cnt}) < (DEPTH - 16) && ~rq_wbusy;
      br_idle <= cq_empty & (rd_out == 10'd0) & ~rd_v_q & ~app_rd_data_valid;
    end
  end

  assign app_en       = mt_sel ? mt_en    : can;
  assign app_cmd      = mt_sel ? mt_cmd   : (q_we ? 3'd0 : 3'd1);
  assign app_addr     = mt_sel ? mt_addr  : {q_addr, 3'b000};
  assign app_wdf_wren = mt_sel ? mt_wren  : (can & q_we & app_rdy);
  assign app_wdf_end  = app_wdf_wren;
  assign app_wdf_data = mt_sel ? mt_wdata : cq_dout[255:0];
  assign app_wdf_mask = 32'd0;
endmodule
`default_nettype wire
