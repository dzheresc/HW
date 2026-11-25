// hr_core: host RAM as a memory port. 128-byte lines, 64-bit data, pcie_7x 64-bit AXI-ST TLPs.
// Commands execute in order; read data returns in order. A read sees every earlier write (PCIe: reads do
// not pass posted writes). Translation: 2 MB pages, 512 entries. No IOMMU is assumed, so anything outside
// 'npages', or issued while bus mastering is off, is refused here: writes swallowed, reads return zero.
`default_nettype none
module hr_core #(parameter TMO_BITS = 25) (          // 2^25 cycles = 134 ms at 250 MHz
  input  wire        clk, rst,
  input  wire [5:0]  window,                              // max reads in flight, 1..32
  output wire        idle,                                // nothing queued, sent-but-unanswered or undelivered
  input  wire [15:0] cfg_id, input wire cfg_bme, input wire [9:0] npages,     // npages 0..512
  input  wire        tbl_we, input wire [8:0] tbl_idx, input wire [42:0] tbl_page,  // bus address [63:21]
  input  wire        cmd_valid, input wire cmd_we, input wire [22:0] cmd_line, output wire cmd_ready, // 2^23 lines = 1 GB
  input  wire [63:0] wd_data, input wire wd_valid, output wire wd_ready,      // 16 words per write
  output reg  [63:0] rd_data, output reg rd_valid, output reg rd_last, output reg rd_err, input wire rd_ready,
  output reg  [63:0] tx_data, output reg [7:0] tx_keep, output reg tx_last, output reg tx_valid, input wire tx_ready,
  input  wire [63:0] rx_data, input wire rx_last, input wire rx_valid,        // always accepted; non-completions ignored
  output reg  [31:0] c_rd, c_wr, c_refused, c_badcpl, c_unexp,
  output reg         fatal   // a read never completed; sticky until rst. Everything after it is refused.
);
  function [31:0] bsw(input [31:0] d); bsw = {d[7:0],d[15:8],d[23:16],d[31:24]}; endfunction
  reg [42:0] tbl [0:511];
  always @(posedge clk) if (tbl_we) tbl[tbl_idx] <= tbl_page;

  // ---- tags: ring of 32 = reorder buffer order
  reg [63:0] rob [0:511];
  reg [31:0] busy, done, bad, zero;
  reg [4:0] atag, dtag;

  // ---- command / TX side
  localparam IDLE=0, XL=1, H0=2, H1=3, DAT=4, DROP=5;
  reg [2:0] st; reg we; reg [22:0] line; reg [42:0] pg; reg ok; reg [3:0] wcnt; reg [31:0] hold; reg tail;
  wire adv = !tx_valid || tx_ready;
  reg dw4;                                                 // above 4 GB (registered in XL for timing)
  reg [31:0] alo, ahi;
  assign cmd_ready = (st==IDLE) && (cmd_we || (!busy[atag] && infl < window));
  assign wd_ready = (st==DROP) || (adv && st==DAT && !tail) || (adv && st==H1 && we && !dw4);
  wire alloc = (st==XL) && !we;
  reg [5:0] infl;
  assign idle = (st==IDLE) && !tx_valid && (infl==0) && !rd_valid;
  wire [31:0] w0 = bsw(wd_data[31:0]), w1 = bsw(wd_data[63:32]);
  always @(posedge clk) begin
    if (adv) tx_valid <= 0;
    case (st)
      IDLE: if (cmd_valid && cmd_ready) begin we <= cmd_we; line <= cmd_line; pg <= tbl[cmd_line[22:14]];
              ok <= cfg_bme && !fatal && ({1'b0,cmd_line[22:14]} < npages); st <= XL; end
      XL: begin wcnt <= 0; tail <= 0; dw4 <= |pg[42:11]; ahi <= pg[42:11]; alo <= {pg[10:0], line[13:0], 7'd0};
            if (!ok) begin c_refused <= c_refused+1; st <= we ? DROP : IDLE; end
            else st <= H0; end
      H0: if (adv) begin tx_valid <= 1; tx_last <= 0; tx_keep <= 8'hff;
            tx_data <= {cfg_id, 3'd0, we ? 5'd0 : rtag, 8'hff, 1'b0, we, dw4, 5'd0, 14'd0, 10'd32}; st <= H1; end
      H1: if (adv) begin
            if (dw4) begin tx_valid <= 1; tx_data <= {alo, ahi}; tx_keep <= 8'hff; tx_last <= !we; st <= we ? DAT : IDLE; if(!we) c_rd<=c_rd+1; end
            else if (!we) begin tx_valid <= 1; tx_data <= {32'd0, alo}; tx_keep <= 8'h0f; tx_last <= 1; st <= IDLE; c_rd<=c_rd+1; end
            else if (wd_valid) begin tx_valid <= 1; tx_data <= {w0, alo}; tx_keep <= 8'hff; tx_last <= 0; hold <= w1; wcnt <= 1; st <= DAT; end
          end
      DAT: if (adv) begin
            if (tail) begin tx_valid <= 1; tx_data <= {32'd0, hold}; tx_keep <= 8'h0f; tx_last <= 1; st <= IDLE; c_wr<=c_wr+1; end
            else if (wd_valid) begin tx_valid <= 1; tx_keep <= 8'hff; wcnt <= wcnt+1;
              tx_data <= dw4 ? {w1,w0} : {w0,hold}; hold <= w1; tx_last <= dw4 && wcnt==15;
              if (wcnt==15) begin if (dw4) begin st <= IDLE; c_wr<=c_wr+1; end else tail <= 1; end end
          end
      DROP: if (wd_valid) begin wcnt <= wcnt+1; if (wcnt==15) st <= IDLE; end
      default: st <= IDLE;
    endcase
    if (rst) begin st <= IDLE; tx_valid <= 0; c_rd<=0; c_wr<=0; c_refused<=0; tail<=0; end
  end
  reg [4:0] rtag;
  always @(posedge clk) if (alloc) rtag <= atag;

  // ---- RX completions (3DW header; payload straddles beats)
  reg [1:0] rs; reg isc, hasd, sbad, ep; reg [31:0] rprev; reg [11:0] bc; reg [9:0] len; reg [4:0] ctag; reg [3:0] wo; reg cok, fin;
  wire [6:0] f = rx_data[30:24];
  wire [4:0] t1 = rx_data[12:8];
  wire shape = (bc!=0) && (bc<=128) && (bc[2:0]==0) && (len!=0) && !len[0] && (len<=32) && ({len,2'b00}<=bc);
  wire cpl1 = rx_valid && rs==1 && isc;
  wire known = !fatal && busy[t1] && !done[t1] && (rx_data[15:13]==0);
  wire good1 = known && !sbad && hasd && shape;
  // Error status (UR/CA) is the last completion for a tag: finish the line as an error. Poisoned data may be
  // one fragment of several, so keep counting and only mark the line bad: freeing the tag early would let the
  // remaining fragments land in its next user. Malformed completions are counted and never finish a line.
  wire cfail = cpl1 && known && sbad;
  wire cpois = cpl1 && good1 && ep;
  wire cdone = (rx_valid && rs==2 && cok && fin && rx_last) || cfail;
  wire [4:0] cdt = cfail ? t1 : ctag;
  wire [11:0] woff = 12'd128 - bc;
  always @(posedge clk) begin
    if (rx_valid) begin
      case (rs)
        0: begin isc <= (f==7'h4a)||(f==7'h0a); hasd <= f[6]; len <= rx_data[9:0]; sbad <= (rx_data[47:45]!=0); ep <= rx_data[14]; bc <= rx_data[43:32]; rs <= rx_last ? 0 : 1; end
        1: begin rprev <= rx_data[63:32]; ctag <= t1; wo <= woff[6:3]; cok <= isc && good1; fin <= ({len,2'b00}==bc); rs <= rx_last ? 0 : 2;
             if (isc && !known) c_unexp <= c_unexp+1; else if (isc && (!good1 || ep)) c_badcpl <= c_badcpl+1; end
        default: begin if (cok) begin rob[{ctag,wo}] <= {bsw(rx_data[31:0]), bsw(rprev)}; wo <= wo+1; end rprev <= rx_data[63:32]; if (rx_last) rs <= 0; end
      endcase
    end
    if (rst) begin rs <= 0; c_badcpl <= 0; c_unexp <= 0; isc<=0; cok<=0; end
  end

  // ---- in-order delivery
  reg [3:0] dcnt;
  reg [TMO_BITS-1:0] tmo;
  wire dadv = !rd_valid || rd_ready;
  wire dgo = dadv && busy[dtag] && done[dtag];
  wire dend = dgo && dcnt==15;
  always @(posedge clk) begin
    // Completion timeout: the oldest read is stuck. Fail every read in flight and ignore completions from then on
    // (a late one must not land in a reused tag), so the port stays alive but inert.
    if (!busy[dtag] || done[dtag]) tmo <= 0; else tmo <= tmo + 1;
    if (&tmo) fatal <= 1;
    if (fatal) begin done <= done | busy; bad <= bad | busy; end
    if (dadv) rd_valid <= 0;
    if (dgo) begin rd_valid <= 1; rd_data <= (zero[dtag]||bad[dtag]) ? 64'd0 : rob[{dtag,dcnt}]; rd_err <= zero[dtag]||bad[dtag]; rd_last <= dcnt==15; dcnt <= dcnt+1; end
    infl <= infl + {5'd0,alloc} - {5'd0,dend};
    if (dend) begin dtag <= dtag+1; busy[dtag] <= 0; done[dtag] <= 0; end
    if (alloc) begin atag <= atag+1; busy[atag] <= 1; bad[atag] <= 0; zero[atag] <= !ok; done[atag] <= !ok; end
    if (cpois) bad[t1] <= 1;
    if (cdone) begin done[cdt] <= 1; if (cfail) bad[cdt] <= 1; end
    if (rst) begin busy<=0; done<=0; bad<=0; zero<=0; atag<=0; dtag<=0; dcnt<=0; rd_valid<=0; tmo<=0; fatal<=0; infl<=0; end
  end
endmodule
`default_nettype wire
