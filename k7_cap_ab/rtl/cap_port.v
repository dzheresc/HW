// One capture input of k7_cap_ab: MAC receiver + test generator + ingress + data/meta FIFOs
// for one SFP cage. Everything left of the FIFOs runs on that cage's RX PCS clock (rx_clk);
// the FIFO read sides and the counter copies run on the PCIe user clock (clk).
//
// The meta entry written to the FIFO is cap_ingress's, with the port number in bits
// [127:121] (cap_dma puts it into byte 13 of the record header).
//
// Configuration arrives from clk through 2-flop synchronisers: quasi-static, change
// snap / tg_cfg / keep bits only while the capture is disabled. cfg_enable may change at
// any time: the ingress decides per frame, at its first word.
`default_nettype none
module cap_port #(
  parameter integer DAW = 15,
  parameter integer MAW = 12,
  parameter [6:0]   PORT = 7'd0
) (
  input  wire          clk,          // PCIe user clock
  input  wire          cap_rst,      // capture reset, clk domain, registered
  input  wire          rx_clk,
  input  wire          rx_rst,       // this cage's RX PCS reset
  input  wire [63:0]   xgmii_rxd,
  input  wire [7:0]    xgmii_rxc,
  input  wire [63:0]   ts_gray,      // Gray-coded timestamp (ts_clk domain)

  // configuration (clk domain)
  input  wire          cfg_enable,   // CTRL.enable & bus master & PORTS bit
  input  wire          cfg_keep_bad,
  input  wire          cfg_keep_fcs,
  input  wire          cfg_tg,
  input  wire [11:0]   cfg_snap_words,
  input  wire [31:0]   cfg_tg_cfg,

  // FIFO read sides (clk, first word fall through)
  output wire [127:0]  m_rdata,
  output wire          m_rvalid,
  input  wire          m_rpop,
  output wire [63:0]   d_rdata,
  output wire          d_rvalid,
  input  wire          d_rpop,

  // counters, clk-domain copies (refreshed every 2^14 rx_clk cycles = 105 us)
  output reg  [63:0]   u_rxf = 0,
  output reg  [63:0]   u_rxb = 0,
  output reg  [63:0]   u_cap = 0,
  output reg  [63:0]   u_drop = 0,
  output reg  [63:0]   u_bad = 0,
  output reg  [63:0]   u_tg = 0,
  output reg  [DAW:0]  u_dmax = 0
);
  function [63:0] g2b(input [63:0] g);
    integer k;
    for (k = 0; k < 64; k = k + 1) g2b[k] = ^(g >> k);
  endfunction

  // ---------------- rx_clk domain ----------------
  (* ASYNC_REG = "TRUE" *) reg [2:0] rrst_s = 3'b111;
  always @(posedge rx_clk or posedge cap_rst)
    if (cap_rst) rrst_s <= 3'b111; else rrst_s <= {rrst_s[1:0], 1'b0};
  wire cap_rst_rx = rrst_s[2];

  (* ASYNC_REG = "TRUE" *) reg [63:0] tsr_s1 = 0, tsr_s2 = 0;
  reg [63:0] ts_r = 0;
  always @(posedge rx_clk) begin tsr_s1 <= ts_gray; tsr_s2 <= tsr_s1; ts_r <= g2b(tsr_s2); end

  (* ASYNC_REG = "TRUE" *) reg [3:0]  cfg_s1 = 0, cfg_s2 = 0;
  (* ASYNC_REG = "TRUE" *) reg [11:0] snap_s1 = 0, snap_s2 = 0;
  (* ASYNC_REG = "TRUE" *) reg [31:0] tg_s1 = 0, tg_s2 = 0;
  always @(posedge rx_clk) begin
    cfg_s1  <= {cfg_tg, cfg_keep_fcs, cfg_keep_bad, cfg_enable};
    cfg_s2  <= cfg_s1;
    snap_s1 <= cfg_snap_words;  snap_s2 <= snap_s1;
    tg_s1   <= cfg_tg_cfg;      tg_s2   <= tg_s1;
  end
  wire rx_enable = cfg_s2[0], rx_keep_bad = cfg_s2[1], rx_keep_fcs = cfg_s2[2], rx_tg = cfg_s2[3];

  // MAC receiver (verilog-ethernet, patched for keep_fcs)
  wire [63:0] mac_tdata;  wire [7:0] mac_tkeep;  wire mac_tvalid, mac_tlast, mac_tuser;
  axis_xgmii_rx_64 #(.PTP_TS_ENABLE(0)) mac_rx (
    .clk(rx_clk), .rst(rx_rst),
    .xgmii_rxd(xgmii_rxd), .xgmii_rxc(xgmii_rxc),
    .m_axis_tdata(mac_tdata), .m_axis_tkeep(mac_tkeep), .m_axis_tvalid(mac_tvalid),
    .m_axis_tlast(mac_tlast), .m_axis_tuser(mac_tuser),
    .ptp_ts(96'd0), .cfg_rx_enable(1'b1), .cfg_keep_fcs(rx_keep_fcs),
    .start_packet(), .error_bad_frame(), .error_bad_fcs()
  );

  wire [63:0] tg_tdata;  wire [7:0] tg_tkeep;  wire tg_tvalid, tg_tlast;  wire [63:0] tg_seq;
  cap_testgen #(.PORT(PORT)) tg (
    .clk(rx_clk), .rst(cap_rst_rx), .enable(rx_tg & rx_enable),
    .cfg_len(tg_s2[15:0]), .cfg_gap(tg_s2[31:16]),
    .m_tdata(tg_tdata), .m_tkeep(tg_tkeep), .m_tvalid(tg_tvalid), .m_tlast(tg_tlast), .seq(tg_seq)
  );

  // input select: switch only between frames of the MAC stream
  reg use_tg = 1'b0, mac_in_frame = 1'b0;
  always @(posedge rx_clk) begin
    if (mac_tvalid) mac_in_frame <= !mac_tlast;
    if (rx_rst) mac_in_frame <= 1'b0;
    if (!mac_in_frame && !mac_tvalid && !tg_tvalid) use_tg <= rx_tg;
  end
  wire [63:0] in_tdata  = use_tg ? tg_tdata  : mac_tdata;
  wire [7:0]  in_tkeep  = use_tg ? tg_tkeep  : mac_tkeep;
  wire        in_tvalid = use_tg ? tg_tvalid : mac_tvalid;
  wire        in_tlast  = use_tg ? tg_tlast  : mac_tlast;
  wire        in_tuser  = use_tg ? 1'b0      : mac_tuser;

  wire         d_we;  wire [63:0] d_wdata;  wire [DAW:0] d_free;
  wire         m_we;  wire [127:0] m_wdata; wire [MAW:0] m_free;
  wire [63:0]  c_rx_frames, c_rx_bytes, c_cap_frames, c_drop_frames, c_bad_frames;
  wire [DAW:0] c_dmax;

  cap_ingress #(.DAW(DAW), .MAW(MAW)) ingress (
    .clk(rx_clk), .rst(cap_rst_rx), .mac_rst(rx_rst & ~use_tg),
    .s_tdata(in_tdata), .s_tkeep(in_tkeep), .s_tvalid(in_tvalid), .s_tlast(in_tlast), .s_tuser(in_tuser),
    .ts(ts_r), .cfg_enable(rx_enable), .cfg_snap_words(snap_s2), .cfg_keep_bad(rx_keep_bad),
    .cfg_keep_fcs(rx_keep_fcs),
    .d_we(d_we), .d_data(d_wdata), .d_free(d_free),
    .m_we(m_we), .m_data(m_wdata), .m_free(m_free),
    .c_rx_frames(c_rx_frames), .c_rx_bytes(c_rx_bytes), .c_cap_frames(c_cap_frames),
    .c_drop_frames(c_drop_frames), .c_bad_frames(c_bad_frames), .c_dfifo_max_used(c_dmax)
  );

  // counter snapshots every 2^14 rx_clk cycles (105 us)
  reg [13:0]  snap_cnt = 0;
  reg         snap_tgl = 1'b0;
  reg [63:0]  sh_rxf = 0, sh_rxb = 0, sh_cap = 0, sh_drop = 0, sh_bad = 0, sh_tg = 0;
  reg [DAW:0] sh_dmax = 0;
  always @(posedge rx_clk) begin
    snap_cnt <= snap_cnt + 1'b1;
    if (snap_cnt == 0) begin
      sh_rxf <= c_rx_frames;  sh_rxb <= c_rx_bytes;  sh_cap <= c_cap_frames;
      sh_drop <= c_drop_frames;  sh_bad <= c_bad_frames;  sh_tg <= tg_seq;  sh_dmax <= c_dmax;
    end
    if (snap_cnt == 14'd8) snap_tgl <= ~snap_tgl;
  end

  // ---------------- FIFOs ----------------
  afifo #(.W(64), .AW(DAW)) dfifo (
    .wclk(rx_clk), .wrst(cap_rst_rx), .wr_en(d_we), .wr_data(d_wdata), .wr_free(d_free),
    .rclk(clk), .rrst(cap_rst), .rd_data(d_rdata), .rd_valid(d_rvalid), .rd_pop(d_rpop), .rd_avail()
  );
  afifo #(.W(128), .AW(MAW)) mfifo (
    .wclk(rx_clk), .wrst(cap_rst_rx), .wr_en(m_we), .wr_data({PORT, m_wdata[120:0]}), .wr_free(m_free),
    .rclk(clk), .rrst(cap_rst), .rd_data(m_rdata), .rd_valid(m_rvalid), .rd_pop(m_rpop), .rd_avail()
  );

  // ---------------- clk domain: counter copies ----------------
  (* ASYNC_REG = "TRUE" *) reg [2:0] snap_s = 0;
  always @(posedge clk) begin
    snap_s <= {snap_s[1:0], snap_tgl};
    if (snap_s[2] != snap_s[1]) begin
      u_rxf <= sh_rxf;  u_rxb <= sh_rxb;  u_cap <= sh_cap;  u_drop <= sh_drop;
      u_bad <= sh_bad;  u_tg <= sh_tg;  u_dmax <= sh_dmax;
    end
  end
endmodule
`default_nettype wire
