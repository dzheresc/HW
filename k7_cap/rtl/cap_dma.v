// Capture DMA engine (k7_cap), PCIe user clock (250 MHz, 64-bit AXI-ST).
//
// 1. Serializer: for each descriptor from the meta FIFO it emits a 16-byte record
//    header and the frame's data words into the prefetch FIFO (discarded records
//    are skipped):
//      word 0  timestamp (6.4 ns ticks)
//      word 1  [15:0] captured length  [31:16] wire length  [39:32] flags
//              [63:48] frames dropped just before this one
//      words   frame bytes, padded to 8 bytes
// 2. Writer: copies the prefetch FIFO into the host ring with posted memory writes
//    (MWr, 3DW header below 4 GB, 4DW above). The ring is nblocks blocks of 2^blk_shift
//    bytes each; block i starts at bus address table[i]. head counts bytes written
//    since the reset (64-bit); the host returns space by writing tail (low 32 bits of
//    its consumed-byte count). The writer never lets head - tail exceed the ring size,
//    so a slow host shows up as ingress drops, not as overwritten data.
//    TLPs never cross an MPS-aligned boundary (so never a 4 KB or block boundary).
//    A partial TLP is sent when data has waited timeout x 4 ns.
// 3. Status: an 8-byte MWr of head to stat_addr after every stat_thresh bytes, and when
//    head has not been reported for timeout x 4 ns. Posted writes stay in order, so
//    every byte below a reported head is already in host memory.
`default_nettype none
module cap_dma (
  input  wire          clk,
  input  wire          rst,           // capture reset (FIFO read side, pointers)

  // meta and data FIFO read sides (first word fall through)
  input  wire [127:0]  m_data,
  input  wire          m_valid,
  output wire          m_pop,
  input  wire [63:0]   d_data,
  input  wire          d_valid,
  output wire          d_pop,

  // configuration
  input  wire          cfg_run,       // enable and bus master enabled
  input  wire [2:0]    cfg_mps,       // Device Control MPS code (0 = 128, else 256)
  input  wire [4:0]    cfg_blk_shift, // 12..30
  input  wire [10:0]   cfg_nblocks,   // 1..1024, ring size <= 1 GB
  input  wire [31:0]   cfg_tail,
  input  wire [63:0]   cfg_stat_addr,
  input  wire [31:0]   cfg_stat_thresh,
  input  wire [15:0]   cfg_timeout,
  input  wire [15:0]   requester_id,
  // block address table write port
  input  wire          tbl_we,
  input  wire [9:0]    tbl_waddr,
  input  wire [63:0]   tbl_wdata,

  // TLP stream to the PCIe core (through the TX arbiter)
  output reg  [63:0]   tx_tdata = 0,
  output reg  [7:0]    tx_tkeep = 0,
  output reg           tx_tlast = 1'b0,
  output reg           tx_tvalid = 1'b0,
  input  wire          tx_tready,

  output reg  [63:0]   head = 0,
  output reg  [63:0]   c_tlps = 0,
  output reg  [63:0]   c_stall = 0,     // decisions where data waited for host ring space
  output reg  [63:0]   c_records = 0,
  output wire [9:0]    pf_level
);
  function [31:0] bswap(input [31:0] x); bswap = {x[7:0], x[15:8], x[23:16], x[31:24]}; endfunction

  // ---------------- serializer -> prefetch FIFO ----------------
  wire [63:0] pf_data;
  wire        pf_valid;
  wire        pf_pop;
  wire [9:0]  pf_avail;
  wire [9:0]  pf_free;
  reg         pf_we = 1'b0;
  reg  [63:0] pf_wdata = 0;

  afifo #(.W(64), .AW(9), .SAME_CLK(1)) prefetch (
    .wclk(clk), .wrst(rst), .wr_en(pf_we), .wr_data(pf_wdata), .wr_free(pf_free),
    .rclk(clk), .rrst(rst), .rd_data(pf_data), .rd_valid(pf_valid), .rd_pop(pf_pop), .rd_avail(pf_avail)
  );
  assign pf_level = pf_avail;

  localparam S_IDLE = 2'd0, S_H1 = 2'd1, S_DATA = 2'd2;
  reg [1:0]  ss = S_IDLE;
  reg [11:0] srem = 0;
  wire [11:0] m_words = (m_data[79:64] + 16'd7) >> 3;
  wire        m_disc  = m_data[120];
  // registered (and so a few writes late): keep a margin for the writes in flight
  reg         pf_room = 1'b0;
  always @(posedge clk) pf_room <= (pf_free > 10'd8);

  reg  m_disc_q = 1'b0;
  assign m_pop = (ss == S_H1);
  assign d_pop = (ss == S_DATA) && d_valid && (m_disc_q || pf_room);

  always @(posedge clk) begin
    pf_we <= 1'b0;
    if (rst) begin
      ss <= S_IDLE;  c_records <= 0;
    end else case (ss)
      S_IDLE: if (m_valid && pf_room) begin
        srem <= m_words;
        m_disc_q <= m_disc;
        pf_we    <= !m_disc;
        pf_wdata <= m_data[63:0];
        ss <= S_H1;
      end
      S_H1: begin   // m_pop this cycle
        pf_we    <= !m_disc_q;
        pf_wdata <= {m_data[119:104], 8'd0, m_data[103:96], m_data[95:80], m_data[79:64]};
        if (!m_disc_q) c_records <= c_records + 1'b1;
        ss <= (srem == 0) ? S_IDLE : S_DATA;
      end
      S_DATA: if (d_pop) begin
        pf_we    <= !m_disc_q;
        pf_wdata <= d_data;
        srem <= srem - 1'b1;
        if (srem == 12'd1) ss <= S_IDLE;
      end
      default: ss <= S_IDLE;
    endcase
  end

  // ---------------- block table ----------------
  (* ram_style = "block" *) reg [63:0] tbl [0:1023];
  reg  [9:0]  nxt_idx = 0;
  reg  [63:0] nxt_base = 0;
  always @(posedge clk) begin
    if (tbl_we) tbl[tbl_waddr] <= tbl_wdata;
    nxt_base <= tbl[nxt_idx];
  end

  // ---------------- writer ----------------
  localparam W_RESET = 4'd0, W_CALC = 4'd1, W_DECIDE = 4'd2, W_HDR1 = 4'd3, W_DATA = 4'd4,
             W_LAST = 4'd5, W_END = 4'd6, W_LOAD = 4'd7, W_CALC2 = 4'd8;
  reg [3:0]  ws = W_RESET;
  reg [63:0] addr = 0;            // bus address of head
  reg [31:0] blk_off = 0;
  reg [63:0] reported = 0;
  reg [15:0] wait_cnt = 0;        // idle cycles (4 ns) data / an unreported head has waited
  reg [3:0]  settle = 0;

  wire [5:0]  mps_words = (cfg_mps == 3'd0) ? 6'd16 : 6'd32;   // 128 or 256 bytes
  wire [31:0] blk_size  = 32'd1 << cfg_blk_shift;
  wire [31:0] ring_size = {21'd0, cfg_nblocks} << cfg_blk_shift;

  reg  [5:0]  c_max = 0;          // words up to the next MPS boundary (registered in CALC)
  reg  [31:0] c_free = 0;         // free bytes in the host ring
  reg  [9:0]  c_avail = 0;
  reg         c_thresh = 1'b0;    // status threshold reached
  reg  [5:0]  t_words = 0;        // payload words (8 bytes) of the TLP being sent
  reg         t_stat = 1'b0;      // status TLP
  reg         t_4dw = 1'b0;
  reg  [63:0] t_addr = 0;
  reg  [5:0]  t_left = 0;
  reg  [31:0] carry = 0;          // 3DW: high DW of the previous payload word

  wire [5:0]  avail6  = (c_avail > 10'd32) ? 6'd32 : c_avail[5:0];
  wire [5:0]  c_words = (avail6 < c_max) ? avail6 : c_max;
  wire        unrep   = (head != reported);
  // registered in W_CALC2, combined in W_DECIDE
  reg  [5:0]  q_words = 0;
  reg         q_free_ok = 1'b0, q_full = 1'b0, q_nz = 1'b0, q_timed_out = 1'b0, q_thresh = 1'b0, q_unrep = 1'b0;
  reg         a_4dw = 1'b0, s_4dw = 1'b0;
  always @(posedge clk) begin
    a_4dw <= (addr[63:32] != 32'd0);
    s_4dw <= (cfg_stat_addr[63:32] != 32'd0);
  end
  wire        free_ok = q_free_ok;
  wire        go_stat_th = q_unrep && q_thresh;
  wire        go_data = q_free_ok && q_nz && (q_full || q_timed_out);
  wire        go_stat_idle = q_unrep && q_timed_out;

  // header fields for the TLP chosen in W_DECIDE (registered in W_CALC2)
  wire        sel_stat = go_stat_th || !go_data;
  wire [63:0] h_addr = sel_stat ? cfg_stat_addr : addr;
  wire        h_4dw  = sel_stat ? s_4dw : a_4dw;
  wire [9:0]  h_len  = sel_stat ? 10'd2 : {3'd0, q_words, 1'b0};
  wire [31:0] h_dw0  = {3'b010 | {2'b00, h_4dw}, 5'b00000, 1'b0, 3'b000, 4'b0000, 1'b0, 1'b0, 2'b00, 2'b00, h_len};
  wire [31:0] h_dw1  = {requester_id, 8'd0, 4'hF, 4'hF};

  // payload source: prefetch head, or head itself for a status TLP
  wire [63:0] src = t_stat ? head : pf_data;
  wire        adv = !tx_tvalid || tx_tready;
  wire        src_ok = t_stat || pf_valid;

  assign pf_pop = !t_stat && adv && pf_valid &&
                  ((ws == W_HDR1 && !t_4dw) || (ws == W_DATA));

  // head / reported after the TLP that W_END completes
  wire [63:0] head_n = t_stat ? head : head + {t_words, 3'b000};
  wire [63:0] rep_n  = t_stat ? head : reported;
  reg         idle_inc = 1'b0;
  always @(posedge clk) idle_inc <= (pf_avail != 0 || unrep) && wait_cnt != 16'hFFFE;

  // values W_END needs, precomputed while the TLP is sent (t_words is stable)
  reg  [31:0] p_blk_off_n = 0;
  reg         p_cross = 1'b0;
  reg  [63:0] p_addr_n = 0, p_head_n = 0;
  reg  [9:0]  p_idx_n = 0;
  always @(posedge clk) begin
    p_blk_off_n <= blk_off + {t_words, 3'b000};
    p_cross     <= (blk_off + {t_words, 3'b000}) == blk_size;
    p_addr_n    <= addr + {t_words, 3'b000};
    p_head_n    <= head_n;
    p_idx_n     <= (nxt_idx + 1'b1 == cfg_nblocks) ? 10'd0 : nxt_idx + 1'b1;
  end

  always @(posedge clk) begin
    if (rst) begin
      ws <= W_RESET;  tx_tvalid <= 1'b0;  tx_tlast <= 1'b0;
      head <= 0;  reported <= 0;  blk_off <= 0;  nxt_idx <= 0;  wait_cnt <= 0;
      c_tlps <= 0;  c_stall <= 0;  settle <= 0;  t_stat <= 1'b0;
    end else begin
      if (tx_tvalid && tx_tready) begin
        tx_tvalid <= 1'b0;
        tx_tlast  <= 1'b0;
      end
      case (ws)
        // load the base of block 0 once the host has enabled the capture (table written)
        W_RESET: begin
          nxt_idx <= 0;
          settle  <= cfg_run ? settle + 1'b1 : 4'd0;
          if (settle == 4'd4) begin
            addr    <= nxt_base;
            nxt_idx <= (cfg_nblocks == 11'd1) ? 10'd0 : 10'd1;
            settle  <= 0;
            ws <= W_LOAD;
          end
        end
        W_CALC: begin
          c_max    <= mps_words - (head[8:3] & (mps_words - 1'b1));
          c_free   <= ring_size - (head[31:0] - cfg_tail);
          c_avail  <= pf_avail;
          c_thresh <= (head[31:0] - reported[31:0]) >= cfg_stat_thresh;
          if (idle_inc) wait_cnt <= wait_cnt + 1'b1;
          ws <= W_CALC2;
        end
        W_CALC2: begin
          q_words     <= c_words;
          q_nz        <= (c_words != 0);
          q_full      <= (avail6 >= c_max);
          q_free_ok   <= (c_free >= {23'd0, c_words, 3'b000});
          q_timed_out <= (wait_cnt >= cfg_timeout);
          q_thresh    <= c_thresh;
          q_unrep     <= unrep;
          if (idle_inc) wait_cnt <= wait_cnt + 1'b1;
          ws <= W_DECIDE;
        end
        W_DECIDE: if (adv) begin
          if (cfg_run && (go_stat_th || go_data || go_stat_idle)) begin
            t_stat  <= sel_stat;
            t_4dw   <= h_4dw;
            t_addr  <= h_addr;
            t_words <= sel_stat ? 6'd1 : q_words;
            tx_tdata <= {h_dw1, h_dw0};  tx_tkeep <= 8'hFF;  tx_tvalid <= 1'b1;
            ws <= W_HDR1;
          end else begin
            if (cfg_run && q_nz && !q_free_ok) c_stall <= c_stall + 1'b1;
            if (idle_inc) wait_cnt <= wait_cnt + 1'b1;
            ws <= W_CALC;
          end
        end
        W_HDR1: if (adv) begin
          if (t_4dw) begin
            tx_tdata <= {t_addr[31:2], 2'b00, t_addr[63:32]};
            tx_tkeep <= 8'hFF;  tx_tvalid <= 1'b1;
            t_left <= t_words;
            ws <= W_DATA;
          end else if (src_ok) begin
            // 3DW: the first payload DW shares the beat with the address
            tx_tdata <= {bswap(src[31:0]), t_addr[31:2], 2'b00};
            tx_tkeep <= 8'hFF;  tx_tvalid <= 1'b1;
            carry  <= src[63:32];
            t_left <= t_words - 1'b1;
            ws <= (t_words == 6'd1) ? W_LAST : W_DATA;
          end
        end
        W_DATA: if (adv && src_ok) begin
          tx_tkeep <= 8'hFF;  tx_tvalid <= 1'b1;
          t_left <= t_left - 1'b1;
          if (t_4dw) begin
            tx_tdata <= {bswap(src[63:32]), bswap(src[31:0])};
            if (t_left == 6'd1) begin tx_tlast <= 1'b1; ws <= W_END; end
          end else begin
            tx_tdata <= {bswap(src[31:0]), bswap(carry)};
            carry <= src[63:32];
            if (t_left == 6'd1) ws <= W_LAST;
          end
        end
        W_LAST: if (adv) begin
          tx_tdata <= {32'd0, bswap(carry)};  tx_tkeep <= 8'h0F;
          tx_tvalid <= 1'b1;  tx_tlast <= 1'b1;
          ws <= W_END;
        end
        W_END: begin
          wait_cnt <= 0;
          c_tlps <= c_tlps + 1'b1;
          // W_CALC work for the next decision, from head / reported after this TLP
          c_max    <= mps_words - (p_head_n[8:3] & (mps_words - 1'b1));
          c_free   <= ring_size - (p_head_n[31:0] - cfg_tail);
          c_avail  <= pf_avail;
          c_thresh <= (p_head_n[31:0] - rep_n[31:0]) >= cfg_stat_thresh;
          if (t_stat) begin
            reported <= head;
            ws <= W_CALC2;
          end else begin
            head <= p_head_n;
            if (p_cross) begin
              blk_off <= 0;
              addr    <= nxt_base;
              nxt_idx <= p_idx_n;
              settle  <= 0;
              ws <= W_LOAD;
            end else begin
              blk_off <= p_blk_off_n;
              addr    <= p_addr_n;
              ws <= W_CALC2;
            end
          end
        end
        // let nxt_base follow nxt_idx (table read latency)
        W_LOAD: begin
          settle <= settle + 1'b1;
          if (settle == 4'd2) ws <= W_CALC;
        end
        default: ws <= W_RESET;
      endcase
    end
  end
endmodule
`default_nettype wire
