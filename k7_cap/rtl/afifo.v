// Dual-clock FIFO (k7_cap): block RAM, Gray-coded pointers, first-word-fall-through
// read side that sustains one word per read clock.
//
// Write side: wr_free is exact for this side's own writes and conservative for the
// reader's frees (they arrive a few cycles late). Writing while wr_free == 0 is ignored.
// Read side: rd_valid/rd_data show the head word, rd_pop removes it. rd_avail counts the
// words the reader can pop (late for the writer's newest words, never too high).
// Resets: wrst/rrst must be asserted together (both sides restart empty). They may be
// asserted asynchronously (the write clock can be stopped), deassertion must be
// synchronous to each side's clock.
// SAME_CLK=1 drops the synchronisers when both sides use one clock.
`default_nettype none
module afifo #(
  parameter integer W = 64,
  parameter integer AW = 10,
  parameter integer SAME_CLK = 0
) (
  input  wire          wclk,
  input  wire          wrst,
  input  wire          wr_en,
  input  wire [W-1:0]  wr_data,
  output wire [AW:0]   wr_free,

  input  wire          rclk,
  input  wire          rrst,
  output wire [W-1:0]  rd_data,
  output wire          rd_valid,
  input  wire          rd_pop,
  output wire [AW:0]   rd_avail
);
  localparam integer DEPTH = 1 << AW;

  function [AW:0] bin2gray(input [AW:0] b); bin2gray = b ^ (b >> 1); endfunction
  function [AW:0] gray2bin(input [AW:0] g);
    integer k;
    begin
      gray2bin[AW] = g[AW];
      for (k = AW - 1; k >= 0; k = k - 1) gray2bin[k] = gray2bin[k+1] ^ g[k];
    end
  endfunction

  (* ram_style = "block" *) reg [W-1:0] mem [0:DEPTH-1];

  // ---------------- write side ----------------
  reg  [AW:0] wbin = 0, wgray = 0;
  reg  [AW:0] rbin_w = 0;
  wire        wr_ok = wr_en && (wr_free != 0);
  assign wr_free = DEPTH - (wbin - rbin_w);

  always @(posedge wclk) if (wr_ok) mem[wbin[AW-1:0]] <= wr_data;

  always @(posedge wclk or posedge wrst) begin
    if (wrst) begin
      wbin <= 0;  wgray <= 0;
    end else if (wr_ok) begin
      wbin  <= wbin + 1'b1;
      wgray <= bin2gray(wbin + 1'b1);
    end
  end

  // ---------------- read side ----------------
  reg  [AW:0] rbin = 0, rgray = 0;      // memory read pointer (reads issued)
  reg  [AW:0] rfree = 0;               // reads completed (slots the writer may reuse)
  reg  [AW:0] wbin_r = 0;

  generate if (SAME_CLK) begin : g_same
    always @* begin rbin_w = rfree; wbin_r = wbin; end
  end else begin : g_sync
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rg_s1 = 0, rg_s2 = 0;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wg_s1 = 0, wg_s2 = 0;
    always @(posedge wclk or posedge wrst)
      if (wrst) begin rg_s1 <= 0; rg_s2 <= 0; rbin_w <= 0; end
      else begin rg_s1 <= rgray; rg_s2 <= rg_s1; rbin_w <= gray2bin(rg_s2); end
    always @(posedge rclk or posedge rrst)
      if (rrst) begin wg_s1 <= 0; wg_s2 <= 0; wbin_r <= 0; end
      else begin wg_s1 <= wgray; wg_s2 <= wg_s1; wbin_r <= gray2bin(wg_s2); end
  end endgenerate

  // Output buffer: 8 registers, fed by a 3-stage block RAM read (address register,
  // RAM, RAM output register) so the RAM can be spread over many tiles at 250 MHz.
  reg  [W-1:0] ob [0:7];
  reg  [2:0]   ob_wp = 0, ob_rp = 0;
  reg  [3:0]   ob_cnt = 0;
  reg          v1 = 1'b0, v2 = 1'b0, v3 = 1'b0;
  (* max_fanout = 16 *) reg [AW-1:0] addr_q = 0;
  reg  [W-1:0] mem_q, mem_q2;
  wire [1:0]   inflight = v1 + v2 + v3;
  wire         mem_ne = (wbin_r != rbin);
  wire         issue  = mem_ne && (ob_cnt + inflight) < 4'd7;
  wire         pop    = rd_pop && (ob_cnt != 0);

  always @(posedge rclk) begin
    if (issue) addr_q <= rbin[AW-1:0];
    if (v1) mem_q <= mem[addr_q];
    if (v2) mem_q2 <= mem_q;
    if (v3) ob[ob_wp] <= mem_q2;
  end

  always @(posedge rclk or posedge rrst) begin
    if (rrst) begin
      rbin <= 0;  rfree <= 0;  rgray <= 0;  v1 <= 1'b0;  v2 <= 1'b0;  v3 <= 1'b0;
      ob_wp <= 0;  ob_rp <= 0;  ob_cnt <= 0;
    end else begin
      v1 <= issue;  v2 <= v1;  v3 <= v2;
      if (issue) rbin <= rbin + 1'b1;
      // a slot is free for the writer once its RAM read has happened (v2)
      if (v2) begin
        rfree <= rfree + 1'b1;
        rgray <= bin2gray(rfree + 1'b1);
      end
      if (v3) ob_wp <= ob_wp + 1'b1;
      if (pop) ob_rp <= ob_rp + 1'b1;
      ob_cnt <= ob_cnt + v3 - pop;
    end
  end

  assign rd_data  = ob[ob_rp];
  assign rd_valid = (ob_cnt != 0);
  assign rd_avail = (wbin_r - rbin) + ob_cnt + inflight;
endmodule
`default_nettype wire
