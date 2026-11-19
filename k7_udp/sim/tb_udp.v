// Two udp_counter instances back to back over XGMII: A (192.168.0.110 -> .215) and
// B (192.168.0.215 -> .110). Each resolves the other with ARP, then sends a datagram
// every PERIOD cycles. The TB decodes A's XGMII TX and prints each frame.
`timescale 1ns/1ps
module tb_udp;
    reg clk = 0;
    always #3.2 clk = ~clk;
    reg rst = 1;

    wire [63:0] a_txd, b_txd;  wire [7:0] a_txc, b_txc;
    reg  tgl = 0;
    wire [63:0] a_cnt, b_cnt;  wire [15:0] a_af, a_rx, b_af, b_rx;  wire a_st, b_st;

    localparam PERIOD = 4000;

    udp_counter A (
        .tx_clk(clk), .tx_rst(rst), .rx_clk(clk), .rx_rst(rst),
        .xgmii_txd(a_txd), .xgmii_txc(a_txc), .xgmii_rxd(b_txd), .xgmii_rxc(b_txc),
        .cfg_tgl(tgl), .cfg_enable(1'b1), .cfg_local_mac(48'h02_4B_37_00_00_6E),
        .cfg_local_ip(32'hC0A8006E), .cfg_dest_ip(32'hC0A800D7), .cfg_gateway_ip(32'hC0A80001),
        .cfg_subnet_mask(32'hFFFFFE00), .cfg_src_port(16'd5000), .cfg_dst_port(16'd5001),
        .cfg_period(PERIOD),
        .st_count(a_cnt), .st_arp_fail(a_af), .st_rx_frames(a_rx), .st_tgl(a_st));

    udp_counter B (
        .tx_clk(clk), .tx_rst(rst), .rx_clk(clk), .rx_rst(rst),
        .xgmii_txd(b_txd), .xgmii_txc(b_txc), .xgmii_rxd(a_txd), .xgmii_rxc(a_txc),
        .cfg_tgl(tgl), .cfg_enable(1'b1), .cfg_local_mac(48'h08_60_6E_81_5E_B4),
        .cfg_local_ip(32'hC0A800D7), .cfg_dest_ip(32'hC0A8006E), .cfg_gateway_ip(32'hC0A80001),
        .cfg_subnet_mask(32'hFFFFFE00), .cfg_src_port(16'd7), .cfg_dst_port(16'd7),
        .cfg_period(PERIOD - 777),
        .st_count(b_cnt), .st_arp_fail(b_af), .st_rx_frames(b_rx), .st_tgl(b_st));

    // ---- XGMII frame decoder for A's TX ----
    reg [7:0] fr [0:2047];
    integer n = 0, in_frame = 0, i, nfr = 0, nudp = 0, errors = 0;
    reg [63:0] val, last_val;
    reg have_last = 0;
    always @(posedge clk) begin
        for (i = 0; i < 8; i = i + 1) begin
            if (a_txc[i] && a_txd[8*i +: 8] == 8'hFB) begin in_frame = 1; n = 0; end
            else if (in_frame && a_txc[i] && a_txd[8*i +: 8] == 8'hFD) begin
                in_frame = 0;  nfr = nfr + 1;
                // fr[0..6] = preamble + SFD, Ethernet header at 7
                if (fr[7+12] == 8'h08 && fr[7+13] == 8'h06)
                    $display("%t A TX ARP %s len %0d", $time, fr[7+21] == 1 ? "request" : "reply", n - 7);
                else if (fr[7+12] == 8'h08 && fr[7+13] == 8'h00 && fr[7+23] == 8'd17) begin
                    val = {fr[49], fr[50], fr[51], fr[52], fr[53], fr[54], fr[55], fr[56]};
                    nudp = nudp + 1;
                    $display("%t A TX UDP len %0d dst %02x:%02x:%02x:%02x:%02x:%02x ip %0d.%0d.%0d.%0d->%0d.%0d.%0d.%0d port %0d->%0d udplen %0d payload %016x",
                        $time, n - 7, fr[7], fr[8], fr[9], fr[10], fr[11], fr[12],
                        fr[33], fr[34], fr[35], fr[36], fr[37], fr[38], fr[39], fr[40],
                        {fr[41], fr[42]}, {fr[43], fr[44]}, {fr[45], fr[46]}, val);
                    if (have_last && val != last_val + 1) begin
                        errors = errors + 1; $display("ERROR: counter not consecutive");
                    end
                    last_val = val;  have_last = 1;
                end else
                    $display("%t A TX other frame len %0d", $time, n - 7);
            end else if (in_frame) begin
                fr[n] = a_txd[8*i +: 8];  n = n + 1;
            end
        end
    end

    initial begin
        #100 rst = 0;
        #100 tgl = 1;     // load the config above
        #(6.4 * PERIOD * 8);
        $display("A: frames %0d udp %0d, st_count %0d arp_fail %0d rx_frames %0d; B st_count %0d rx %0d",
                 nfr, nudp, a_cnt, a_af, a_rx, b_cnt, b_rx);
        if (nudp >= 5 && errors == 0 && a_af == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
