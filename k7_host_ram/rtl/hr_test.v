// hr_test: hr_core + register block + traffic generator/checker. Word offsets in BAR0 0x100..0x1FF:
// 00 CTRL W[0] start [1] write(1)/read+check(0) [2] random order [31] hold reset (only when idle)
// 04 STAT R[0] busy [1] BME [2] fatal [3] core idle   08 NPAGES  0C TBL_IDX  10 TBL_LO  14 TBL_HI(stores, idx++)
// 18 SPAN (2^n lines) 1C BASE line 20 COUNT lines 24 SEED 28 WINDOW 1..32
// 2C ERRS words 30 RD_ERR lines 34/38 CYCLES 3C LAT_MIN 40 LAT_MAX 44/48 LAT_SUM (cycles, command to first data)
// 4C core reads 50 writes 54 refused 58 bad completions 5C unexpected completions 60 first bad line 64 got lines
`default_nettype none
module hr_test #(parameter TMO_BITS = 25) (
  input  wire clk, rst, input wire req, we, input wire [5:0] addr, input wire [31:0] wdata, output reg [31:0] rdata,
  input  wire [15:0] cfg_id, input wire cfg_bme,
  output wire [63:0] tx_data, output wire [7:0] tx_keep, output wire tx_last, tx_valid, input wire tx_ready,
  input  wire [63:0] rx_data, input wire rx_last, rx_valid, output wire led_busy, led_err, led_fatal
);
  reg hold=1, wr=0, rnd=0, go=0, busy=0; reg [9:0] npages=0; reg [8:0] tidx=0; reg [31:0] tlo=0; reg twe=0; reg [42:0] tpg=0; reg [8:0] twi=0;
  reg [4:0] span=0; reg [22:0] base=0; reg [31:0] count=0, seed=0; reg [5:0] win=16;
  reg [31:0] errs=0, rderr=0, lmin=0, lmax=0, got=0; reg [47:0] cyc=0, lsum=0; reg [22:0] fbad=0; reg hasbad=0;
  wire core_idle, fatal; wire [31:0] c_rd, c_wr, c_ref, c_bad, c_un; wire crst = rst | hold;
  reg [22:0] mask; always @(posedge clk) mask <= (23'd1 << span) - 23'd1;
  // walk -> line: bijective on 2^span
  function [22:0] ln(input [22:0] w, input [22:0] m, input r, input [22:0] b); reg [22:0] x; begin x = w & m; ln = b + (r ? (x ^ (x >> 5)) : x); end endfunction
  wire [22:0] step = rnd ? 23'h1E3779 : 23'd1;             // odd
  function [63:0] pat(input [22:0] l, input [3:0] k, input [31:0] s); pat = {s ^ {l,9'h0}, l, k, 5'h15}; endfunction

  reg [22:0] w_c, w_d, w_k, l_c, l_d, l_k; reg [31:0] left; reg cv; reg [31:0] dleft; reg dv; reg [3:0] dk, kk;
  wire cr, wdr, rv, rl, re; wire [63:0] rd;
  hr_core #(.TMO_BITS(TMO_BITS)) core (.clk(clk), .rst(crst), .window(win), .idle(core_idle), .cfg_id(cfg_id), .cfg_bme(cfg_bme), .npages(npages),
    .tbl_we(twe), .tbl_idx(twi), .tbl_page(tpg), .cmd_valid(cv), .cmd_we(wr), .cmd_line(l_c), .cmd_ready(cr),
    .wd_data(pat(l_d, dk, seed)), .wd_valid(dv), .wd_ready(wdr), .rd_data(rd), .rd_valid(rv), .rd_last(rl), .rd_err(re), .rd_ready(1'b1),
    .tx_data(tx_data), .tx_keep(tx_keep), .tx_last(tx_last), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_last(rx_last), .rx_valid(rx_valid),
    .c_rd(c_rd), .c_wr(c_wr), .c_refused(c_ref), .c_badcpl(c_bad), .c_unexp(c_un), .fatal(fatal));

  // checker pipeline
  reg [63:0] q_rd, q_ex; reg q_v, q_l, q_e; reg [22:0] q_ln; reg c_v, c_l, c_e, c_ne; reg [22:0] c_ln;
  // latency
  reg [31:0] ts [0:31]; reg [4:0] tp, tg; reg [31:0] now; reg [31:0] lat; reg lv; reg [31:0] tsq; reg tv; reg [31:0] nowq;
  // Last write line may still be in the core when its command is accepted: busy ends when the core is idle too.
  reg [2:0] quiet;
  reg init; reg init2;
  always @(posedge clk) begin
    now <= now + 1; go <= 0; twe <= 0; init <= go; init2 <= init;
    if (req && we) case (addr)
      6'h00: begin hold <= wdata[31]; if (!busy) begin wr <= wdata[1]; rnd <= wdata[2]; go <= wdata[0]; end end
      6'h02: npages <= wdata[9:0];
      6'h03: tidx <= wdata[8:0];
      6'h04: tlo <= wdata;
      6'h05: begin twe <= 1; twi <= tidx; tpg <= {wdata, tlo[31:21]}; tidx <= tidx + 1; end
      6'h06: span <= wdata[4:0]; 6'h07: base <= wdata[22:0]; 6'h08: count <= wdata; 6'h09: seed <= wdata; 6'h0A: win <= wdata[5:0];
      default: ;
    endcase
    if (req) case (addr)
      6'h00: rdata <= {hold, 28'd0, rnd, wr, 1'b0}; 6'h01: rdata <= {28'd0, core_idle, fatal, cfg_bme, busy | go | init | init2};
      6'h02: rdata <= {22'd0, npages}; 6'h06: rdata <= {27'd0, span}; 6'h07: rdata <= {9'd0, base}; 6'h08: rdata <= count; 6'h09: rdata <= seed; 6'h0A: rdata <= {26'd0, win};
      6'h0B: rdata <= errs; 6'h0C: rdata <= rderr; 6'h0D: rdata <= cyc[31:0]; 6'h0E: rdata <= {16'd0, cyc[47:32]}; 6'h0F: rdata <= lmin; 6'h10: rdata <= lmax;
      6'h11: rdata <= lsum[31:0]; 6'h12: rdata <= {16'd0, lsum[47:32]}; 6'h13: rdata <= c_rd; 6'h14: rdata <= c_wr; 6'h15: rdata <= c_ref; 6'h16: rdata <= c_bad; 6'h17: rdata <= c_un;
      6'h18: rdata <= {9'd0, fbad}; 6'h19: rdata <= got; default: rdata <= 32'd0;
    endcase
    // start
    if (go) begin busy <= 1; errs<=0; rderr<=0; cyc<=0; lmin<=32'hffffffff; lmax<=0; lsum<=0; got<=0; hasbad<=0; fbad<=0; w_c<=0; w_d<=0; w_k<=0; left<=count; dleft<= wr ? count : 0; cv<=0; dv<=0; dk<=0; kk<=0; tp<=0; tg<=0; quiet<=0; end
    else if (init) begin l_c <= ln(w_c,mask,rnd,base); l_d <= ln(w_d,mask,rnd,base); l_k <= ln(w_k,mask,rnd,base); w_c <= w_c+step; w_d <= w_d+step; w_k <= w_k+step; end
    else if (init2) begin cv <= (left!=0); dv <= (dleft!=0); end
    else if (busy) begin
      cyc <= cyc + 1;
      if (cv && cr) begin left <= left-1; cv <= (left!=1); l_c <= ln(w_c,mask,rnd,base); w_c <= w_c+step; if (!wr) begin ts[tp] <= now; tp <= tp+1; end end
      if (dv && wdr) begin dk <= dk+1; if (dk==15) begin dleft <= dleft-1; dv <= (dleft!=1); l_d <= ln(w_d,mask,rnd,base); w_d <= w_d+step; end end
      quiet <= (!cv && !dv && core_idle && !q_v && !c_v && !tv && !lv) ? quiet + 1 : 0;
      if (&quiet) busy <= 0;
    end
    // check
    q_v <= rv; q_rd <= rd; q_ex <= pat(l_k, kk, seed); q_l <= rl; q_e <= re; q_ln <= l_k;
    if (rv) begin kk <= kk+1; if (rl) begin l_k <= ln(w_k,mask,rnd,base); w_k <= w_k+step; end end
    c_v <= q_v; c_ne <= (q_rd != q_ex); c_l <= q_l; c_e <= q_e; c_ln <= q_ln;
    if (c_v) begin if (c_ne) begin errs <= errs+1; if (!hasbad) begin hasbad <= 1; fbad <= c_ln; end end if (c_l) begin got <= got+1; if (c_e) rderr <= rderr+1; end end
    tv <= rv && kk==0; nowq <= now; if (rv && kk==0) begin tsq <= ts[tg]; tg <= tg+1; end
    lv <= tv; lat <= nowq - tsq;
    if (lv) begin lsum <= lsum + lat; if (lat<lmin) lmin <= lat; if (lat>lmax) lmax <= lat; end
    if (rst) begin hold<=1; busy<=0; go<=0; npages<=0; cv<=0; dv<=0; now<=0; init<=0; init2<=0; win<=16; end
    else if (hold) begin busy<=0; cv<=0; dv<=0; end
  end
  assign led_busy = busy; assign led_err = (errs!=0) | (rderr!=0); assign led_fatal = fatal;
endmodule
`default_nettype wire
