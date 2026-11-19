// UDP counter sender on one 10GBASE-R port (k7_udp).
//
// verilog-ethernet 10G MAC (eth_mac_10g_fifo) + UDP/IP stack (udp_complete_64, with
// ARP) on the XGMII of the PCS. Once per period (default 1 s of the 156.25 MHz PCS
// clock) it sends one UDP datagram whose 8-byte payload is a 64-bit counter in
// network (big-endian) byte order. The counter is the number of datagrams handed to
// the stack before this one (0, 1, 2, ...). UDP checksum is 0 (allowed for IPv4).
// The stack answers ARP requests for local_ip and resolves dest_ip (or the gateway
// when dest_ip is off-subnet) before the first datagram.
//
// Clock domains: logic and MAC TX run on tx_clk (the gated 156.25 MHz TX PCS clock);
// the MAC RX side runs on rx_clk (RX PCS clock) and crosses in the MAC's async FIFO.
// Configuration arrives from another clock domain (cfg_*), held stable around a
// toggle (cfg_tgl): it is captured here 3 tx_clk cycles after the toggle is seen.
// Status (st_*) changes on tx_clk at most once per datagram; st_tgl flips after
// each update so the reader can capture it once the toggle has crossed.
`default_nettype none
module udp_counter (
    input  wire        tx_clk,
    input  wire        tx_rst,
    input  wire        rx_clk,
    input  wire        rx_rst,

    output wire [63:0] xgmii_txd,
    output wire [7:0]  xgmii_txc,
    input  wire [63:0] xgmii_rxd,
    input  wire [7:0]  xgmii_rxc,

    // configuration (foreign clock domain, see above)
    input  wire        cfg_tgl,
    input  wire        cfg_enable,
    input  wire [47:0] cfg_local_mac,
    input  wire [31:0] cfg_local_ip,
    input  wire [31:0] cfg_dest_ip,
    input  wire [31:0] cfg_gateway_ip,
    input  wire [31:0] cfg_subnet_mask,
    input  wire [15:0] cfg_src_port,
    input  wire [15:0] cfg_dst_port,
    input  wire [31:0] cfg_period,      // tx_clk cycles between datagrams

    // status (tx_clk domain), snapshot once per period (mid-period)
    output reg  [63:0] st_count = 64'd0,   // next counter value = datagrams sent
    output reg  [15:0] st_arp_fail = 16'd0,
    output reg  [15:0] st_rx_frames = 16'd0, // good frames received by the MAC
    output reg         st_tgl = 1'b0
);
    // ---------------- defaults (match udp_regs) and config capture ----------------
    reg        enable      = 1'b1;
    reg [47:0] local_mac   = 48'h02_4B_37_00_00_6E;
    reg [31:0] local_ip    = {8'd192, 8'd168, 8'd0, 8'd110};
    reg [31:0] dest_ip     = {8'd192, 8'd168, 8'd0, 8'd215};
    reg [31:0] gateway_ip  = {8'd192, 8'd168, 8'd0, 8'd1};
    reg [31:0] subnet_mask = 32'hFFFF_FE00;
    reg [15:0] src_port    = 16'd5000;
    reg [15:0] dst_port    = 16'd5000;
    reg [31:0] period      = 32'd156_250_000;

    (* ASYNC_REG = "TRUE" *) reg [2:0] cfg_tgl_s = 3'b000;
    reg [1:0] cap_dly = 2'b00;
    always @(posedge tx_clk) begin
        cfg_tgl_s <= {cfg_tgl_s[1:0], cfg_tgl};
        cap_dly   <= {cap_dly[0], cfg_tgl_s[2] ^ cfg_tgl_s[1]};
        if (cap_dly[1]) begin
            enable      <= cfg_enable;
            local_mac   <= cfg_local_mac;
            local_ip    <= cfg_local_ip;
            dest_ip     <= cfg_dest_ip;
            gateway_ip  <= cfg_gateway_ip;
            subnet_mask <= cfg_subnet_mask;
            src_port    <= cfg_src_port;
            dst_port    <= cfg_dst_port;
            period      <= (cfg_period < 32'd1000) ? 32'd1000 : cfg_period;
        end
    end

    // ---------------- MAC ----------------
    wire [63:0] mac_tx_tdata, mac_rx_tdata;
    wire [7:0]  mac_tx_tkeep, mac_rx_tkeep;
    wire        mac_tx_tvalid, mac_tx_tready, mac_tx_tlast, mac_tx_tuser;
    wire        mac_rx_tvalid, mac_rx_tready, mac_rx_tlast, mac_rx_tuser;
    wire        rx_good_frame;

    eth_mac_10g_fifo #(
        .ENABLE_PADDING(1), .ENABLE_DIC(1), .MIN_FRAME_LENGTH(64),
        .TX_FIFO_DEPTH(4096), .TX_FRAME_FIFO(1),
        .RX_FIFO_DEPTH(4096), .RX_FRAME_FIFO(1)
    ) u_mac (
        .rx_clk(rx_clk), .rx_rst(rx_rst), .tx_clk(tx_clk), .tx_rst(tx_rst),
        .logic_clk(tx_clk), .logic_rst(tx_rst),
        .tx_axis_tdata(mac_tx_tdata), .tx_axis_tkeep(mac_tx_tkeep), .tx_axis_tvalid(mac_tx_tvalid),
        .tx_axis_tready(mac_tx_tready), .tx_axis_tlast(mac_tx_tlast), .tx_axis_tuser(mac_tx_tuser),
        .rx_axis_tdata(mac_rx_tdata), .rx_axis_tkeep(mac_rx_tkeep), .rx_axis_tvalid(mac_rx_tvalid),
        .rx_axis_tready(mac_rx_tready), .rx_axis_tlast(mac_rx_tlast), .rx_axis_tuser(mac_rx_tuser),
        .xgmii_rxd(xgmii_rxd), .xgmii_rxc(xgmii_rxc), .xgmii_txd(xgmii_txd), .xgmii_txc(xgmii_txc),
        .tx_fifo_overflow(), .tx_fifo_bad_frame(), .tx_fifo_good_frame(),
        .rx_error_bad_frame(), .rx_error_bad_fcs(), .rx_fifo_overflow(), .rx_fifo_bad_frame(),
        .rx_fifo_good_frame(rx_good_frame),
        .cfg_ifg(8'd12), .cfg_tx_enable(1'b1), .cfg_rx_enable(1'b1)
    );

    // ---------------- Ethernet framing ----------------
    wire        rx_eth_hdr_valid, rx_eth_hdr_ready;
    wire [47:0] rx_eth_dest_mac, rx_eth_src_mac;
    wire [15:0] rx_eth_type;
    wire [63:0] rx_eth_tdata;  wire [7:0] rx_eth_tkeep;
    wire        rx_eth_tvalid, rx_eth_tready, rx_eth_tlast, rx_eth_tuser;

    wire        tx_eth_hdr_valid, tx_eth_hdr_ready;
    wire [47:0] tx_eth_dest_mac, tx_eth_src_mac;
    wire [15:0] tx_eth_type;
    wire [63:0] tx_eth_tdata;  wire [7:0] tx_eth_tkeep;
    wire        tx_eth_tvalid, tx_eth_tready, tx_eth_tlast, tx_eth_tuser;

    eth_axis_rx #(.DATA_WIDTH(64)) u_eth_rx (
        .clk(tx_clk), .rst(tx_rst),
        .s_axis_tdata(mac_rx_tdata), .s_axis_tkeep(mac_rx_tkeep), .s_axis_tvalid(mac_rx_tvalid),
        .s_axis_tready(mac_rx_tready), .s_axis_tlast(mac_rx_tlast), .s_axis_tuser(mac_rx_tuser),
        .m_eth_hdr_valid(rx_eth_hdr_valid), .m_eth_hdr_ready(rx_eth_hdr_ready),
        .m_eth_dest_mac(rx_eth_dest_mac), .m_eth_src_mac(rx_eth_src_mac), .m_eth_type(rx_eth_type),
        .m_eth_payload_axis_tdata(rx_eth_tdata), .m_eth_payload_axis_tkeep(rx_eth_tkeep),
        .m_eth_payload_axis_tvalid(rx_eth_tvalid), .m_eth_payload_axis_tready(rx_eth_tready),
        .m_eth_payload_axis_tlast(rx_eth_tlast), .m_eth_payload_axis_tuser(rx_eth_tuser),
        .busy(), .error_header_early_termination()
    );

    eth_axis_tx #(.DATA_WIDTH(64)) u_eth_tx (
        .clk(tx_clk), .rst(tx_rst),
        .s_eth_hdr_valid(tx_eth_hdr_valid), .s_eth_hdr_ready(tx_eth_hdr_ready),
        .s_eth_dest_mac(tx_eth_dest_mac), .s_eth_src_mac(tx_eth_src_mac), .s_eth_type(tx_eth_type),
        .s_eth_payload_axis_tdata(tx_eth_tdata), .s_eth_payload_axis_tkeep(tx_eth_tkeep),
        .s_eth_payload_axis_tvalid(tx_eth_tvalid), .s_eth_payload_axis_tready(tx_eth_tready),
        .s_eth_payload_axis_tlast(tx_eth_tlast), .s_eth_payload_axis_tuser(tx_eth_tuser),
        .m_axis_tdata(mac_tx_tdata), .m_axis_tkeep(mac_tx_tkeep), .m_axis_tvalid(mac_tx_tvalid),
        .m_axis_tready(mac_tx_tready), .m_axis_tlast(mac_tx_tlast), .m_axis_tuser(mac_tx_tuser),
        .busy()
    );

    // ---------------- UDP/IP stack ----------------
    reg [63:0] count = 64'd0;
    // network byte order: AXI byte 0 (tdata[7:0]) goes on the wire first = MSB
    wire [63:0] payload = {count[7:0], count[15:8], count[23:16], count[31:24],
                           count[39:32], count[47:40], count[55:48], count[63:56]};
    reg         udp_hdr_valid = 1'b0;
    wire        udp_hdr_ready;
    reg         udp_tvalid = 1'b0;
    wire        udp_tready;
    wire        arp_failed;

    // received IP / UDP traffic is not used: drain it
    wire rx_ip_hdr_valid, rx_ip_tvalid, rx_ip_tlast, rx_ip_tuser;
    wire rx_udp_hdr_valid, rx_udp_tvalid, rx_udp_tlast, rx_udp_tuser;

    localparam integer ARP_RETRY = 156_250_000 / 4;   // 0.25 s

    udp_complete_64 #(
        .ARP_CACHE_ADDR_WIDTH(2),
        .ARP_REQUEST_RETRY_COUNT(4),
        .ARP_REQUEST_RETRY_INTERVAL(ARP_RETRY),
        .ARP_REQUEST_TIMEOUT(156_250_000 * 30),
        .UDP_CHECKSUM_GEN_ENABLE(0)
    ) u_udp (
        .clk(tx_clk), .rst(tx_rst),
        .s_eth_hdr_valid(rx_eth_hdr_valid), .s_eth_hdr_ready(rx_eth_hdr_ready),
        .s_eth_dest_mac(rx_eth_dest_mac), .s_eth_src_mac(rx_eth_src_mac), .s_eth_type(rx_eth_type),
        .s_eth_payload_axis_tdata(rx_eth_tdata), .s_eth_payload_axis_tkeep(rx_eth_tkeep),
        .s_eth_payload_axis_tvalid(rx_eth_tvalid), .s_eth_payload_axis_tready(rx_eth_tready),
        .s_eth_payload_axis_tlast(rx_eth_tlast), .s_eth_payload_axis_tuser(rx_eth_tuser),
        .m_eth_hdr_valid(tx_eth_hdr_valid), .m_eth_hdr_ready(tx_eth_hdr_ready),
        .m_eth_dest_mac(tx_eth_dest_mac), .m_eth_src_mac(tx_eth_src_mac), .m_eth_type(tx_eth_type),
        .m_eth_payload_axis_tdata(tx_eth_tdata), .m_eth_payload_axis_tkeep(tx_eth_tkeep),
        .m_eth_payload_axis_tvalid(tx_eth_tvalid), .m_eth_payload_axis_tready(tx_eth_tready),
        .m_eth_payload_axis_tlast(tx_eth_tlast), .m_eth_payload_axis_tuser(tx_eth_tuser),
        // raw IP input: unused
        .s_ip_hdr_valid(1'b0), .s_ip_hdr_ready(),
        .s_ip_dscp(6'd0), .s_ip_ecn(2'd0), .s_ip_length(16'd0), .s_ip_ttl(8'd0), .s_ip_protocol(8'd0),
        .s_ip_source_ip(32'd0), .s_ip_dest_ip(32'd0),
        .s_ip_payload_axis_tdata(64'd0), .s_ip_payload_axis_tkeep(8'd0), .s_ip_payload_axis_tvalid(1'b0),
        .s_ip_payload_axis_tready(), .s_ip_payload_axis_tlast(1'b0), .s_ip_payload_axis_tuser(1'b0),
        // raw IP output: drained
        .m_ip_hdr_valid(rx_ip_hdr_valid), .m_ip_hdr_ready(1'b1),
        .m_ip_eth_dest_mac(), .m_ip_eth_src_mac(), .m_ip_eth_type(), .m_ip_version(), .m_ip_ihl(),
        .m_ip_dscp(), .m_ip_ecn(), .m_ip_length(), .m_ip_identification(), .m_ip_flags(),
        .m_ip_fragment_offset(), .m_ip_ttl(), .m_ip_protocol(), .m_ip_header_checksum(),
        .m_ip_source_ip(), .m_ip_dest_ip(),
        .m_ip_payload_axis_tdata(), .m_ip_payload_axis_tkeep(), .m_ip_payload_axis_tvalid(rx_ip_tvalid),
        .m_ip_payload_axis_tready(1'b1), .m_ip_payload_axis_tlast(rx_ip_tlast), .m_ip_payload_axis_tuser(rx_ip_tuser),
        // UDP input: the counter datagram
        .s_udp_hdr_valid(udp_hdr_valid), .s_udp_hdr_ready(udp_hdr_ready),
        .s_udp_ip_dscp(6'd0), .s_udp_ip_ecn(2'd0), .s_udp_ip_ttl(8'd64),
        .s_udp_ip_source_ip(local_ip), .s_udp_ip_dest_ip(dest_ip),
        .s_udp_source_port(src_port), .s_udp_dest_port(dst_port),
        .s_udp_length(16'd16), .s_udp_checksum(16'd0),
        .s_udp_payload_axis_tdata(payload), .s_udp_payload_axis_tkeep(8'hFF),
        .s_udp_payload_axis_tvalid(udp_tvalid), .s_udp_payload_axis_tready(udp_tready),
        .s_udp_payload_axis_tlast(1'b1), .s_udp_payload_axis_tuser(1'b0),
        // UDP output: drained
        .m_udp_hdr_valid(rx_udp_hdr_valid), .m_udp_hdr_ready(1'b1),
        .m_udp_eth_dest_mac(), .m_udp_eth_src_mac(), .m_udp_eth_type(), .m_udp_ip_version(),
        .m_udp_ip_ihl(), .m_udp_ip_dscp(), .m_udp_ip_ecn(), .m_udp_ip_length(),
        .m_udp_ip_identification(), .m_udp_ip_flags(), .m_udp_ip_fragment_offset(), .m_udp_ip_ttl(),
        .m_udp_ip_protocol(), .m_udp_ip_header_checksum(), .m_udp_ip_source_ip(), .m_udp_ip_dest_ip(),
        .m_udp_source_port(), .m_udp_dest_port(), .m_udp_length(), .m_udp_checksum(),
        .m_udp_payload_axis_tdata(), .m_udp_payload_axis_tkeep(), .m_udp_payload_axis_tvalid(rx_udp_tvalid),
        .m_udp_payload_axis_tready(1'b1), .m_udp_payload_axis_tlast(rx_udp_tlast), .m_udp_payload_axis_tuser(rx_udp_tuser),
        .ip_rx_busy(), .ip_tx_busy(), .udp_rx_busy(), .udp_tx_busy(),
        .ip_rx_error_header_early_termination(), .ip_rx_error_payload_early_termination(),
        .ip_rx_error_invalid_header(), .ip_rx_error_invalid_checksum(),
        .ip_tx_error_payload_early_termination(), .ip_tx_error_arp_failed(arp_failed),
        .udp_rx_error_header_early_termination(), .udp_rx_error_payload_early_termination(),
        .udp_tx_error_payload_early_termination(),
        .local_mac(local_mac), .local_ip(local_ip), .gateway_ip(gateway_ip), .subnet_mask(subnet_mask),
        .clear_arp_cache(1'b0)
    );

    // ---------------- once-per-period sender ----------------

    reg [31:0] tick_cnt = 32'd0;
    reg        tick = 1'b0;
    always @(posedge tx_clk) begin
        tick <= 1'b0;
        if (tx_rst) tick_cnt <= 32'd0;
        else if (tick_cnt >= period - 1) begin tick_cnt <= 32'd0; tick <= 1'b1; end
        else tick_cnt <= tick_cnt + 1'b1;
    end

    always @(posedge tx_clk) begin
        if (udp_hdr_valid && udp_hdr_ready) udp_hdr_valid <= 1'b0;
        if (udp_tvalid && udp_tready) begin
            udp_tvalid <= 1'b0;
            count      <= count + 1'b1;
        end
        // a tick while the previous datagram is still pending (ARP in progress) is skipped
        if (tick && enable && !udp_hdr_valid && !udp_tvalid) begin
            udp_hdr_valid <= 1'b1;
            udp_tvalid    <= 1'b1;
        end
        if (tx_rst) begin
            udp_hdr_valid <= 1'b0;
            udp_tvalid    <= 1'b0;
            count         <= 64'd0;
        end
    end

    // ---------------- status ----------------
    // Snapshot once per period, half a period after the send, so the values are
    // stable for ~0.5 s around each st_tgl flip (safe to capture in another domain).
    reg [15:0] arp_fail_cnt = 16'd0, rx_frames_cnt = 16'd0;
    reg        snap = 1'b0;
    always @(posedge tx_clk) begin
        if (arp_failed)    arp_fail_cnt  <= arp_fail_cnt + 1'b1;
        if (rx_good_frame) rx_frames_cnt <= rx_frames_cnt + 1'b1;
        snap <= (tick_cnt == {1'b0, period[31:1]});
        if (snap) begin
            st_count     <= count;
            st_arp_fail  <= arp_fail_cnt;
            st_rx_frames <= rx_frames_cnt;
        end
        st_tgl <= st_tgl ^ snap;
    end
endmodule
`default_nettype wire
