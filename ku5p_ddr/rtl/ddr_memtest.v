// In-fabric DDR memory test on the MIG native interface (ui_clk domain).
// Writes a pattern over [base, base+len) words, then reads it back and checks
// it, each pass at the full rate the controller accepts (one 32-byte word per
// ui_clk when app_rdy). Measures each pass in ui_clk cycles.
//
// Pattern for the 32-bit lane j of word w (byte address a = 32*w + 4*j):
//   mode 0: a ^ seed               (address in data: catches aliasing)
//   mode 1: ~(a ^ seed)
//   mode 2: xorshift32(a ^ seed)   (pseudo-random, address dependent)
//   mode 3: seed on even words, ~seed on odd words (all bits toggle every BL8)
//
// cfg_* are quasi-static (written by the host while idle): false paths.
`default_nettype none
module ddr_memtest #(
  parameter AW = 26
) (
  input  wire           clk,          // ui_clk
  input  wire           rst,
  input  wire           start,        // one-cycle pulse
  input  wire [AW-1:0]  cfg_base,     // word index
  input  wire [AW:0]    cfg_len,      // words (1 .. 2^AW)
  input  wire           cfg_wr,       // do the write pass
  input  wire           cfg_rd,       // do the read/verify pass
  input  wire [1:0]     cfg_mode,
  input  wire [31:0]    cfg_seed,
  input  wire           br_idle,

  output reg            sel = 1'b0,
  output wire           app_en,
  output wire [2:0]     app_cmd,
  output wire [28:0]    app_addr,
  output wire           app_wren,
  output wire [255:0]   app_wdata,
  input  wire           app_rdy,
  input  wire           app_wdf_rdy,
  input  wire           rd_valid,
  input  wire [255:0]   rd_data,

  output reg            busy = 1'b0,
  output reg  [31:0]    xst_errs,      // mismatched 32-bit lanes (saturating)
  output reg  [31:0]    xst_wcyc,
  output reg  [31:0]    xst_rcyc,
  output reg  [31:0]    xst_err_addr,  // byte address of the first bad lane
  output reg  [31:0]    xst_err_exp,
  output reg  [31:0]    xst_err_got
);
  function [31:0] lanepat(input [AW-1:0] w, input [2:0] j, input [1:0] mode, input [31:0] seed);
    reg [31:0] a, x;
    begin
      a = {w, j, 2'b00};
      a = a[31:0] ^ seed;
      x = a ^ (a << 13);
      x = x ^ (x >> 17);
      x = x ^ (x << 5);
      case (mode)
        2'd0: lanepat = a;
        2'd1: lanepat = ~a;
        2'd2: lanepat = x;
        default: lanepat = w[0] ? ~seed : seed;
      endcase
    end
  endfunction
  function [255:0] wordpat(input [AW-1:0] w, input [1:0] mode, input [31:0] seed);
    integer j;
    begin
      for (j = 0; j < 8; j = j + 1) wordpat[32 * j +: 32] = lanepat(w, j[2:0], mode, seed);
    end
  endfunction

  localparam S_IDLE = 3'd0, S_WAIT = 3'd1, S_WR = 3'd2, S_RD = 3'd3, S_DRAIN = 3'd4, S_END = 3'd5;
  reg [2:0]    st = S_IDLE;
  reg [AW-1:0] a_cur, a_nxt;       // issue address and the one after
  reg [AW:0]   left;               // commands left to issue in this pass
  reg [255:0]  wd;                 // pattern for a_cur
  reg [AW:0]   r_left;             // read data still expected
  reg [AW-1:0] r_nxt;
  reg [255:0]  r_exp;
  reg [AW-1:0] r_w;                // word of r_exp

  wire issue_wr = (st == S_WR) && left != 0;
  wire issue_rd = (st == S_RD) && left != 0;
  assign app_en   = issue_rd | (issue_wr & app_wdf_rdy);
  assign app_cmd  = issue_wr ? 3'd0 : 3'd1;
  assign app_addr = {a_cur, 3'b000};
  assign app_wren = issue_wr & app_wdf_rdy & app_rdy;
  assign app_wdata = wd;
  wire acc = app_en & app_rdy;

  // read check pipeline: stage 1 register data + expected, stage 2 lane compare, stage 3 count
  reg          v1 = 1'b0, v2 = 1'b0;
  reg [255:0]  d1, e1, d2, e2;
  reg [AW-1:0] w1, w2;
  reg [7:0]    bad2;
  integer k;
  reg [3:0]    nbad;
  reg [2:0]    first_lane;
  always @* begin
    nbad = 4'd0;
    first_lane = 3'd0;
    for (k = 7; k >= 0; k = k - 1)
      if (bad2[k]) begin
        nbad = nbad + 4'd1;
        first_lane = k[2:0];
      end
  end

  reg have_err;
  always @(posedge clk) begin
    v1 <= 1'b0;
    v2 <= v1;
    if (rd_valid && sel && r_left != 0) begin
      v1 <= 1'b1;
      d1 <= rd_data;
      e1 <= r_exp;
      w1 <= r_w;
      r_w <= r_nxt;
      r_nxt <= r_nxt + 1'b1;
      r_exp <= wordpat(r_nxt, cfg_mode, cfg_seed);
      r_left <= r_left - 1'b1;
    end
    d2 <= d1;  e2 <= e1;  w2 <= w1;
    for (k = 0; k < 8; k = k + 1) bad2[k] <= v1 && (d1[32 * k +: 32] != e1[32 * k +: 32]);
    if (v2 && nbad != 0) begin
      xst_errs <= (xst_errs > 32'hFFFF_FFF0) ? 32'hFFFF_FFFF : xst_errs + nbad;
      if (!have_err) begin
        have_err <= 1'b1;
        xst_err_addr <= {w2, first_lane, 2'b00};
        xst_err_exp <= e2[32 * first_lane +: 32];
        xst_err_got <= d2[32 * first_lane +: 32];
      end
    end

    if (acc) begin
      a_cur <= a_nxt;
      a_nxt <= a_nxt + 1'b1;
      wd <= wordpat(a_nxt, cfg_mode, cfg_seed);
      left <= left - 1'b1;
    end

    case (st)
      S_IDLE: if (start) begin
        busy <= 1'b1;
        xst_errs <= 32'd0;  xst_wcyc <= 32'd0;  xst_rcyc <= 32'd0;
        xst_err_addr <= 32'hFFFF_FFFF;  xst_err_exp <= 32'd0;  xst_err_got <= 32'd0;
        have_err <= 1'b0;
        st <= S_WAIT;
      end
      S_WAIT: if (br_idle) begin
        sel <= 1'b1;
        a_cur <= cfg_base;  a_nxt <= cfg_base + 1'b1;
        wd <= wordpat(cfg_base, cfg_mode, cfg_seed);
        left <= cfg_len;
        r_w <= cfg_base;  r_nxt <= cfg_base + 1'b1;
        r_exp <= wordpat(cfg_base, cfg_mode, cfg_seed);
        r_left <= cfg_rd ? cfg_len : {(AW+1){1'b0}};
        st <= cfg_wr ? S_WR : (cfg_rd ? S_RD : S_END);
      end
      S_WR: begin
        xst_wcyc <= xst_wcyc + 1'b1;
        if (left == 0 || (left == 1 && acc)) begin
          a_cur <= cfg_base;  a_nxt <= cfg_base + 1'b1;
          wd <= wordpat(cfg_base, cfg_mode, cfg_seed);
          left <= cfg_len;
          st <= cfg_rd ? S_RD : S_END;
        end
      end
      S_RD: begin
        xst_rcyc <= xst_rcyc + 1'b1;
        if (left == 0 || (left == 1 && acc)) st <= S_DRAIN;
      end
      S_DRAIN: begin
        xst_rcyc <= xst_rcyc + 1'b1;
        if (r_left == 0) st <= S_END;
      end
      S_END: if (!v1 && !v2) begin   // let the compare pipeline finish
        sel <= 1'b0;
        busy <= 1'b0;
        st <= S_IDLE;
      end
      default: st <= S_IDLE;
    endcase

    if (rst) begin
      st <= S_IDLE;
      sel <= 1'b0;
      busy <= 1'b0;
      v1 <= 1'b0;
      v2 <= 1'b0;
    end
  end
endmodule
`default_nettype wire
