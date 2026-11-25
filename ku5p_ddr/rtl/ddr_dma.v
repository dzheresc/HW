// Simple single-transfer DMA between host memory and DDR over the
// pcie4_uscale_plus requester interfaces (RQ out, RC in), 256-bit, DWORD-aligned
// mode, straddle off, client tags.
//
//   dir 0 (H2C, host -> DDR): memory reads of REQ bytes (min(MRRS, 512)) to the host;
//          completions are written to DDR at tag_base[tag] + (REQ - byte_count).
//   dir 1 (C2H, DDR -> host): DDR reads, packed into memory writes of PAY bytes
//          (min(MPS, 256)).
//
// Requirements (the host tool checks them): host address 512-byte aligned,
// DDR address 32-byte aligned, length a non-zero multiple of 512 bytes.
// With these, every completion (RCB 64 B) carries a multiple of 32 bytes and
// starts on a 32-byte boundary of the request.
//
// RQ descriptor (PG213): DW0-1 address, DW2 [10:0] dword count, [14:11] type
// (0 MRd, 1 MWr), DW3 [7:0] tag, [24] requester ID enable (0: the core's ID).
// RC descriptor: DW0 [11:0] lower address, [15:12] error code, [28:16] byte
// count, [30] request completed; DW1 [10:0] dword count, [13:11] status;
// DW2 [7:0] tag. Payload starts at DW3 of the first beat.
`default_nettype none
module ddr_dma #(
  parameter AW   = 26,
  parameter NTAG = 16,
  parameter TW   = 4             // log2(NTAG) (2017.4 synth rejects $clog2 in localparams here)
) (
  input  wire           clk,
  input  wire           rst,

  input  wire           start,
  input  wire           cfg_dir,
  input  wire [63:0]    cfg_host,
  input  wire [31:0]    cfg_ddr,
  input  wire [31:0]    cfg_len,
  input  wire [1:0]     max_payload,   // cfg_max_payload
  input  wire [2:0]     max_read_req,  // cfg_max_read_req
  input  wire           bme,           // bus master enable
  output reg            busy = 1'b0,
  output reg            done = 1'b0,
  output reg  [2:0]     err = 3'd0,    // 1 no BME, 2 bad completion status, 3 timeout, 4 bad args
  output reg  [31:0]    cycles = 32'd0,
  output wire [31:0]    dbg,
  output reg  [31:0]    dbg_cnt = 32'd0,  // [15:0] RQ beats sent, [31:16] RC beats received (since start)
  output reg  [95:0]    dbg_rc = 96'd0,   // descriptor of the last RC first beat
  output reg  [31:0]    dbg_stall = 32'd0, // cycles with RC data waiting on the DDR port (H2C)

  // DDR port (ddr_bridge user side)
  output wire           c_valid,
  input  wire           c_ready,
  output wire           c_we,
  output wire [AW-1:0]  c_addr,
  output wire [255:0]   c_wdata,
  input  wire           r_valid,
  input  wire [255:0]   r_data,
  output wire           r_pop,

  // requester request
  output wire [255:0]   rq_tdata,
  output wire [7:0]     rq_tkeep,
  output wire           rq_tlast,
  output wire [61:0]    rq_tuser,
  output wire           rq_tvalid,
  input  wire           rq_tready,
  // requester completion
  input  wire [255:0]   rc_tdata,
  input  wire           rc_tlast,
  input  wire           rc_tvalid,
  output wire           rc_tready
);

  reg         dir;
  reg [63:0]  haddr;
  reg [AW-1:0] daddr;           // next DDR word (C2H read issue, H2C request base)
  reg [31:0]  nrem;             // H2C: requests left; C2H: TLPs left
  reg [AW:0]  rd_left;          // C2H: DDR reads left to issue
  reg [AW:0]  w_left;           // H2C: words still to receive
  reg [9:0]   req_b;            // request bytes (H2C) / payload bytes (C2H)
  reg [2:0]   wpt;              // C2H words per TLP (4 or 8)
  reg [7:0]   tail;             // C2H drain delay
  reg [28:0]  tmo;

  localparam S_IDLE = 3'd0, S_H2C = 3'd1, S_C2H = 3'd2, S_TAIL = 3'd3;
  reg [2:0] st = S_IDLE;

  // ---------------- RQ source (into a register slice) ----------------
  reg  [255:0] s_data;
  reg  [7:0]   s_keep;
  reg          s_last;
  wire         s_valid;
  wire         s_ready;

  // H2C: tags
  reg [NTAG-1:0] tag_busy = {NTAG{1'b0}};
  reg [TW-1:0]   ntag;
  reg [AW-1:0]   tag_base [0:NTAG-1];
  wire           h_req = (st == S_H2C) && nrem != 0 && !tag_busy[ntag];

  // C2H packer
  reg          c_hdr;           // next beat is a TLP's first beat
  reg [2:0]    c_wl;            // words left in this TLP after the current hold
  reg [127:0]  hold;
  wire         c_act = (st == S_C2H) && nrem != 0;
  wire         c_need = c_hdr || c_wl != 0;   // this beat consumes a DDR word
  wire         c_beat = c_act && (!c_need || r_valid);

  assign s_valid = h_req | c_beat;

  wire [10:0] dwc = {1'b0, req_b} >> 2;
  wire [127:0] desc = {1'b0, 3'b000, 3'b000, 1'b0, 16'h0000,
                       (dir ? 8'h00 : {{(8-TW){1'b0}}, ntag}),
                       16'h0000, 1'b0, (dir ? 4'b0001 : 4'b0000), dwc,
                       haddr[63:2], 2'b00};
  always @* begin
    if (!dir) begin
      s_data = {128'd0, desc};
      s_keep = 8'h0F;
      s_last = 1'b1;
    end else if (c_hdr) begin
      s_data = {r_data[127:0], desc};
      s_keep = 8'hFF;
      s_last = 1'b0;
    end else if (c_wl != 0) begin
      s_data = {r_data[127:0], hold};
      s_keep = 8'hFF;
      s_last = 1'b0;
    end else begin
      s_data = {128'd0, hold};
      s_keep = 8'h0F;
      s_last = 1'b1;
    end
  end
  wire s_acc = s_valid & s_ready;
  assign r_pop = dir && c_beat && c_need && s_ready;

  axis_reg #(.W(256 + 8 + 1)) rq_slice (
    .clk(clk), .rst(rst),
    .s_valid(s_valid), .s_ready(s_ready), .s_data({s_last, s_keep, s_data}),
    .m_valid(rq_tvalid), .m_ready(rq_tready), .m_data({rq_tlast, rq_tkeep, rq_tdata})
  );
  assign rq_tuser = {54'd0, 4'hF, 4'hF};   // last BE, first BE (all requests > 1 DW)

  // ---------------- RC sink (H2C) ----------------
  reg          rc_first = 1'b1;
  reg [159:0]  rc_hold;
  reg [AW-1:0] wa;
  wire [12:0]  rc_bc   = rc_tdata[28:16];
  wire         rc_done = rc_tdata[30];
  wire [2:0]   rc_stat = rc_tdata[45:43];
  wire [TW-1:0] rc_tag = rc_tdata[64 +: TW];
  wire [12:0]  rc_off  = {3'd0, req_b} - rc_bc;
  wire         h_act   = (st == S_H2C);
  assign rc_tready = h_act ? c_ready : 1'b1;
  wire         rc_acc = rc_tvalid & rc_tready;
  wire         rc_emit = h_act & rc_acc & ~rc_first;

  // ---------------- DDR port ----------------
  wire c_rd = (st == S_C2H) && rd_left != 0;
  assign c_valid = rc_emit | c_rd;
  assign c_we    = h_act;
  assign c_addr  = h_act ? wa : daddr;
  assign c_wdata = {rc_tdata[95:0], rc_hold};

  // tag bookkeeping
  wire [NTAG-1:0] t_set = (h_req && s_acc) ? ({{(NTAG-1){1'b0}}, 1'b1} << ntag) : {NTAG{1'b0}};
  wire [NTAG-1:0] t_clr = (h_act && rc_acc && rc_first && rc_done) ?
                          ({{(NTAG-1){1'b0}}, 1'b1} << rc_tag) : {NTAG{1'b0}};

  // dbg: [31:24] busy tags 0-7, [23:16] next tag, [10:8] state, [7] rc_first, [6] c_hdr, [4:2] c_wl
  assign dbg = {tag_busy[7:0], {(8-TW){1'b0}}, ntag, 5'd0, st, rc_first, c_hdr, 1'b0, c_wl, 2'b00};

  always @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE;
      busy <= 1'b0;
      done <= 1'b0;
      err <= 3'd0;
      tag_busy <= {NTAG{1'b0}};
      rc_first <= 1'b1;
    end else begin
      tag_busy <= (tag_busy | t_set) & ~t_clr;
      if (busy) cycles <= cycles + 1'b1;
      if (rq_tvalid && rq_tready) dbg_cnt[15:0] <= dbg_cnt[15:0] + 1'b1;
      if (rc_acc) dbg_cnt[31:16] <= dbg_cnt[31:16] + 1'b1;
      if (rc_acc && rc_first) dbg_rc <= rc_tdata[95:0];
      if (h_act && rc_tvalid && !rc_tready) dbg_stall <= dbg_stall + 1'b1;
      // timeout: no progress for ~1 s
      if (s_acc || rc_acc || (c_rd && c_ready)) tmo <= 29'd0;
      else if (busy) tmo <= tmo + 1'b1;

      // RC beats: first beat sets the write address, every later beat writes one word
      if (rc_acc) begin
        rc_first <= rc_tlast;
        rc_hold <= rc_tdata[255:96];
        if (rc_first) begin
          wa <= tag_base[rc_tag] + rc_off[12:5];
          if (h_act && rc_stat != 3'd0) err <= 3'd2;
        end else
          wa <= wa + 1'b1;
      end
      if (rc_emit) w_left <= w_left - 1'b1;

      if (h_req && s_acc) begin
        tag_base[ntag] <= daddr;
        daddr <= daddr + (req_b >> 5);
        haddr <= haddr + req_b;
        nrem <= nrem - 1'b1;
        ntag <= ntag + 1'b1;
      end

      if (c_rd && c_ready) begin
        daddr <= daddr + 1'b1;
        rd_left <= rd_left - 1'b1;
      end
      if (dir && c_beat && s_ready) begin
        if (c_hdr) begin
          c_hdr <= 1'b0;
          c_wl <= wpt - 3'd1;
          hold <= r_data[255:128];
        end else if (c_wl != 0) begin
          c_wl <= c_wl - 3'd1;
          hold <= r_data[255:128];
        end else begin
          c_hdr <= 1'b1;
          haddr <= haddr + req_b;
          nrem <= nrem - 1'b1;
        end
      end

      case (st)
        S_IDLE: if (start) begin
          done <= 1'b0;
          err <= 3'd0;
          cycles <= 32'd0;
          dbg_cnt <= 32'd0;
          dbg_stall <= 32'd0;
          dir <= cfg_dir;
          haddr <= {cfg_host[63:9], 9'd0};
          daddr <= cfg_ddr[AW+4:5];
          tmo <= 29'd0;
          c_hdr <= 1'b1;
          c_wl <= 3'd0;
          ntag <= {TW{1'b0}};
          rc_first <= 1'b1;
          if (!bme) begin
            err <= 3'd1;
            done <= 1'b1;
          end else if (cfg_len == 0 || cfg_len[8:0] != 0 || cfg_host[8:0] != 0 || cfg_ddr[4:0] != 0) begin
            err <= 3'd4;
            done <= 1'b1;
          end else begin
            busy <= 1'b1;
            if (cfg_dir) begin
              // payload = min(MPS, 256)
              req_b <= max_payload == 2'd0 ? 10'd128 : 10'd256;
              wpt   <= max_payload == 2'd0 ? 3'd4 : 3'd0;   // 8 words wraps to 0 (see c_wl)
              nrem  <= max_payload == 2'd0 ? cfg_len >> 7 : cfg_len >> 8;
              rd_left <= cfg_len[AW+5:5];
              st <= S_C2H;
            end else begin
              // read request = min(MRRS, 512)
              req_b <= max_read_req == 3'd0 ? 10'd128 : max_read_req == 3'd1 ? 10'd256 : 10'd512;
              nrem  <= max_read_req == 3'd0 ? cfg_len >> 7 : max_read_req == 3'd1 ? cfg_len >> 8 : cfg_len >> 9;
              w_left <= cfg_len[AW+5:5];
              st <= S_H2C;
            end
          end
        end
        S_H2C: begin
          if (w_left == 0 && tag_busy == 0) begin
            busy <= 1'b0;
            done <= 1'b1;
            st <= S_IDLE;
          end
        end
        S_C2H: begin
          tail <= 8'd0;
          if (nrem == 0 && !rq_tvalid) st <= S_TAIL;
        end
        S_TAIL: begin   // let the core take the last writes before reporting done
          tail <= tail + 1'b1;
          if (tail == 8'd255) begin
            busy <= 1'b0;
            done <= 1'b1;
            st <= S_IDLE;
          end
        end
        default: st <= S_IDLE;
      endcase
      if (busy && tmo[28]) begin   // ~1 s at 250 MHz
        err <= 3'd3;
        busy <= 1'b0;
        done <= 1'b1;
        tag_busy <= {NTAG{1'b0}};
        st <= S_IDLE;
      end
    end
  end
endmodule

// Two-entry AXI-Stream register slice: registered ready and data both ways.
module axis_reg #(
  parameter W = 32
) (
  input  wire         clk,
  input  wire         rst,
  input  wire         s_valid,
  output wire         s_ready,
  input  wire [W-1:0] s_data,
  output wire         m_valid,
  input  wire         m_ready,
  output wire [W-1:0] m_data
);
  reg [W-1:0] d0, d1;
  reg         v0 = 1'b0, v1 = 1'b0;
  assign s_ready = ~v1;
  assign m_valid = v0;
  assign m_data  = d0;
  always @(posedge clk) begin
    if (rst) begin
      v0 <= 1'b0;
      v1 <= 1'b0;
    end else if (!v0 || m_ready) begin
      if (v1) begin
        d0 <= d1;  v0 <= 1'b1;  v1 <= 1'b0;
      end else begin
        d0 <= s_data;  v0 <= s_valid;
      end
    end else if (s_valid && !v1) begin
      d1 <= s_data;  v1 <= 1'b1;
    end
  end
endmodule
`default_nettype wire
