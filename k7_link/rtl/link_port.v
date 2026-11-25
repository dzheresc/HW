// One 10GBASE-R port of k7_link: verilog-ethernet 10G MAC + reply-only responder + counters.
// Logic and MAC TX run on tx_clk (gated 156.25 MHz TX PCS clock); the MAC RX side runs on
// rx_clk (this port's recovered PCS clock) and crosses in the MAC's RX async FIFO, which
// passes only whole frames with a good FCS.
`default_nettype none
module link_port #(
    parameter [47:0] LOCAL_MAC = 48'd0,
    parameter [31:0] LOCAL_IP  = 32'd0,
    parameter integer SNAP_BITS = 16      // counter snapshot period: 2^SNAP_BITS tx_clk cycles
) (
    input  wire        tx_clk, tx_rst, rx_clk, rx_rst,
    output wire [63:0] xgmii_txd,
    output wire [7:0]  xgmii_txc,
    input  wire [63:0] xgmii_rxd,
    input  wire [7:0]  xgmii_rxc,
    // counters, snapshot (tx_clk); st_tgl flips with each snapshot, which then holds 0.4 ms
    output reg  [255:0] st = 256'd0,      // {tx, udp, icmp, arp, rx_ovf, rx_badframe, rx_badfcs, rx_good}
    output reg          st_tgl = 1'b0,
    output reg          act = 1'b0        // flips about every 54 ms while frames move (LED)
);
    wire [63:0] rxd, txd;  wire [7:0] rxk, txk;
    wire rxv, rxr, rxl, rxu, txv, txr, txl, txu;
    wire e_good, e_fcs, e_bad, e_ovf, e_tx, e_arp, e_icmp, e_udp;

    eth_mac_10g_fifo #(
        .ENABLE_PADDING(1), .ENABLE_DIC(1), .MIN_FRAME_LENGTH(64),
        .TX_FIFO_DEPTH(16384), .TX_FRAME_FIFO(1),
        .RX_FIFO_DEPTH(16384), .RX_FRAME_FIFO(1)
    ) u_mac (
        .rx_clk(rx_clk), .rx_rst(rx_rst), .tx_clk(tx_clk), .tx_rst(tx_rst),
        .logic_clk(tx_clk), .logic_rst(tx_rst), .ptp_sample_clk(1'b0),
        .tx_axis_tdata(txd), .tx_axis_tkeep(txk), .tx_axis_tvalid(txv),
        .tx_axis_tready(txr), .tx_axis_tlast(txl), .tx_axis_tuser(txu),
        .m_axis_tx_ptp_ts_96(), .m_axis_tx_ptp_ts_tag(), .m_axis_tx_ptp_ts_valid(), .m_axis_tx_ptp_ts_ready(1'b1),
        .rx_axis_tdata(rxd), .rx_axis_tkeep(rxk), .rx_axis_tvalid(rxv),
        .rx_axis_tready(rxr), .rx_axis_tlast(rxl), .rx_axis_tuser(rxu),
        .xgmii_rxd(xgmii_rxd), .xgmii_rxc(xgmii_rxc), .xgmii_txd(xgmii_txd), .xgmii_txc(xgmii_txc),
        .tx_error_underflow(), .tx_fifo_overflow(), .tx_fifo_bad_frame(), .tx_fifo_good_frame(e_tx),
        .rx_error_bad_frame(e_bad), .rx_error_bad_fcs(e_fcs), .rx_fifo_overflow(e_ovf),
        .rx_fifo_bad_frame(), .rx_fifo_good_frame(e_good),
        .ptp_ts_96(96'd0), .ptp_ts_step(1'b0),
        .cfg_ifg(8'd12), .cfg_tx_enable(1'b1), .cfg_rx_enable(1'b1)
    );

    echo_core #(.LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP)) u_echo (
        .clk(tx_clk), .rst(tx_rst),
        .s_tdata(rxd), .s_tkeep(rxk), .s_tvalid(rxv), .s_tready(rxr), .s_tlast(rxl), .s_tuser(rxu),
        .m_tdata(txd), .m_tkeep(txk), .m_tvalid(txv), .m_tready(txr), .m_tlast(txl), .m_tuser(txu),
        .ev_arp(e_arp), .ev_icmp(e_icmp), .ev_udp(e_udp)
    );

    reg [255:0] c = 256'd0;
    reg [SNAP_BITS-1:0] snap_cnt = 0;
    reg [22:0] act_cnt = 23'd0;           // 2^23 / 156.25 MHz = 54 ms
    reg        seen = 1'b0;
    wire [7:0] ev = {e_tx, e_udp, e_icmp, e_arp, e_ovf, e_bad, e_fcs, e_good};
    integer i;
    always @(posedge tx_clk) begin
        for (i = 0; i < 8; i = i + 1) c[32*i +: 32] <= c[32*i +: 32] + ev[i];
        snap_cnt <= snap_cnt + 1'b1;
        if (&snap_cnt) begin
            st     <= c;
            st_tgl <= ~st_tgl;
        end
        act_cnt <= act_cnt + 1'b1;
        seen <= (seen & ~(&act_cnt)) | e_good | e_tx;
        if (&act_cnt) act <= seen ? ~act : 1'b0;
    end
endmodule
`default_nettype wire
