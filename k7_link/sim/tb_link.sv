// link_port against a tester MAC over XGMII. The reference model rebuilds each expected reply
// from scratch (full ICMP checksum), in order; any unexpected transmit is an error.
// Runs: directed accept/refuse cases, bad FCS, then line-rate bursts of random pings.
`timescale 1ns/1ps
module tb_link;
    localparam [47:0] DMAC = 48'h02_4B_37_00_01_01, HMAC = 48'hB8_CE_F6_11_22_33;
    localparam [31:0] DIP = 32'h0A0A0001, HIP = 32'h0A0A0002;

    reg clk = 0, tclk = 0, rst = 1;
    always #3.2 clk = ~clk;         // DUT TX / logic clock
    always #3.2003 tclk = ~tclk;    // tester clock (= DUT recovered RX clock), -47 ppm

    wire [63:0] h2d_d, d2h_d;  wire [7:0] h2d_c, d2h_c;
    reg  corrupt = 0;
    wire [63:0] h2d_dx = corrupt ? h2d_d ^ 64'h0000_0100_0000_0000 : h2d_d;
    wire [255:0] st;  wire st_tgl, act;

    link_port #(.LOCAL_MAC(DMAC), .LOCAL_IP(DIP), .SNAP_BITS(6)) dut (
        .tx_clk(clk), .tx_rst(rst), .rx_clk(tclk), .rx_rst(rst),
        .xgmii_txd(d2h_d), .xgmii_txc(d2h_c), .xgmii_rxd(h2d_dx), .xgmii_rxc(h2d_c),
        .st(st), .st_tgl(st_tgl), .act(act));

    reg [63:0] td = 0;  reg [7:0] tk = 0;  reg tv = 0, tl = 0;  wire tr;
    wire [63:0] rd;  wire [7:0] rk;  wire rv, rl, ru;
    eth_mac_10g_fifo #(.TX_FIFO_DEPTH(65536), .RX_FIFO_DEPTH(65536)) tester (
        .rx_clk(clk), .rx_rst(rst), .tx_clk(tclk), .tx_rst(rst), .logic_clk(tclk), .logic_rst(rst),
        .ptp_sample_clk(1'b0), .tx_axis_tdata(td), .tx_axis_tkeep(tk), .tx_axis_tvalid(tv), .tx_axis_tready(tr),
        .tx_axis_tlast(tl), .tx_axis_tuser(1'b0), .m_axis_tx_ptp_ts_ready(1'b1),
        .rx_axis_tdata(rd), .rx_axis_tkeep(rk), .rx_axis_tvalid(rv), .rx_axis_tready(1'b1),
        .rx_axis_tlast(rl), .rx_axis_tuser(ru),
        .xgmii_rxd(d2h_d), .xgmii_rxc(d2h_c), .xgmii_txd(h2d_d), .xgmii_txc(h2d_c),
        .ptp_ts_96(96'd0), .ptp_ts_step(1'b0), .cfg_ifg(8'd12), .cfg_tx_enable(1'b1), .cfg_rx_enable(1'b1));

    typedef byte unsigned frame_t[$];
    frame_t exp_q[$], sent, got;
    integer errors = 0, replies = 0;

    function automatic bit [15:0] csum(frame_t f, int from, int to);   // bytes [from, to)
        bit [31:0] s = 0;
        for (int i = from; i < to; i += 2) s += (f[i] << 8) + ((i + 1 < to) ? f[i+1] : 0);
        while (s >> 16) s = (s & 32'hFFFF) + (s >> 16);
        return ~s[15:0];
    endfunction
    function automatic void put(ref frame_t f, input bit [63:0] v, int n);
        for (int i = n - 1; i >= 0; i--) f.push_back(v[8*i +: 8]);
    endfunction
    function automatic frame_t pad(frame_t f);
        while (f.size() < 60) f.push_back(8'h00);
        return f;
    endfunction
    function automatic frame_t arp(bit [47:0] dst, bit [15:0] op, bit [31:0] tpa);
        frame_t f;
        put(f, dst, 6); put(f, HMAC, 6); put(f, 16'h0806, 2);
        put(f, 48'h0001_0800_0604, 6); put(f, op, 2); put(f, HMAC, 6); put(f, HIP, 4);
        put(f, 0, 6); put(f, tpa, 4);
        return pad(f);
    endfunction
    // payload bytes after the 8-byte ICMP/UDP header
    function automatic frame_t ip(bit [47:0] dmac, bit [31:0] dip, bit [7:0] proto, int plen,
                                  bit [15:0] f0, bit [15:0] f1, bit [15:0] frag);
        frame_t f; bit [15:0] c;
        put(f, dmac, 6); put(f, HMAC, 6); put(f, 16'h0800, 2);
        put(f, 16'h4500, 2); put(f, 28 + plen, 2); put(f, $urandom, 2); put(f, frag, 2);
        put(f, 8'd64, 1); put(f, proto, 1); put(f, 0, 2); put(f, HIP, 4); put(f, dip, 4);
        c = csum(f, 14, 34);  f[24] = c[15:8];  f[25] = c[7:0];
        put(f, f0, 2); put(f, f1, 2);
        if (proto == 1) put(f, $urandom, 4);
        else begin put(f, 8 + plen, 2); put(f, 16'hBEEF, 2); end
        for (int i = 0; i < plen; i++) f.push_back($urandom);
        if (proto == 1) begin
            f[36] = 0; f[37] = 0; c = csum(f, 34, 42 + plen);  f[36] = c[15:8];  f[37] = c[7:0];
        end
        return pad(f);
    endfunction
    function automatic frame_t ping(int plen); return ip(DMAC, DIP, 1, plen, 16'h0800, 0, 16'h4000); endfunction

    // expected reply to an accepted frame
    function automatic frame_t reply(frame_t q);
        frame_t f = q; bit [15:0] c; int iplen;
        for (int i = 0; i < 6; i++) begin f[i] = q[6+i]; f[6+i] = DMAC[8*(5-i) +: 8]; end
        if (q[13] == 8'h06) begin
            f[21] = 2;
            for (int i = 0; i < 6; i++) begin f[22+i] = DMAC[8*(5-i) +: 8]; f[32+i] = q[22+i]; end
            for (int i = 0; i < 4; i++) begin f[28+i] = DIP[8*(3-i) +: 8]; f[38+i] = q[28+i]; end
        end else begin
            iplen = (q[16] << 8) + q[17];
            for (int i = 0; i < 4; i++) begin f[26+i] = q[30+i]; f[30+i] = q[26+i]; end
            if (q[23] == 1) begin
                f[34] = 0; f[36] = 0; f[37] = 0; c = csum(f, 34, 14 + iplen); f[36] = c[15:8]; f[37] = c[7:0];
            end else for (int i = 0; i < 2; i++) begin f[34+i] = q[36+i]; f[36+i] = q[34+i]; end
        end
        return f;
    endfunction

    task automatic send(frame_t f, bit accept);
        if (accept) exp_q.push_back(reply(f));
        for (int i = 0; i < f.size(); i += 8) begin
            td = 0; tk = 0;
            for (int j = 0; j < 8 && i + j < f.size(); j++) begin td[8*j +: 8] = f[i+j]; tk[j] = 1; end
            tv = 1;  tl = (i + 8 >= f.size());
            @(posedge tclk); while (!tr) @(posedge tclk);
            #0.5;
        end
        tv = 0; tl = 0;
    endtask
    task automatic settle(int n); repeat (n) @(posedge tclk); #0.5; endtask

    always @(posedge tclk) if (rv) begin
        for (int j = 0; j < 8; j++) if (rk[j]) got.push_back(rd[8*j +: 8]);
        if (rl) begin
            replies = replies + 1;
            if (ru) begin errors++; $display("ERROR: bad FCS on reply"); end
            if (exp_q.size() == 0) begin errors++; $display("%t ERROR: unexpected frame, %0d bytes", $time, got.size()); end
            else begin
                sent = exp_q.pop_front();
                if (sent != got) begin
                    errors++;
                    $display("%t ERROR: reply mismatch, len %0d expected %0d", $time, got.size(), sent.size());
                    for (int i = 0; i < 48; i++) if (got[i] != sent[i]) $display("  byte %0d got %02x exp %02x", i, got[i], sent[i]);
                end
            end
            got.delete();
        end
    end

    integer n, r0, len;
    realtime t0;
    frame_t f;  reg [15:0] cc;
    initial begin
        #200 rst = 0;
        settle(300);
        if (replies != 0) begin errors++; $display("ERROR: transmit before any request"); end
        // accepted
        send(arp(48'hFFFFFFFFFFFF, 1, DIP), 1);
        send(arp(DMAC, 1, DIP), 1);
        for (int p = 0; p < 80; p++) send(ping(p), 1);
        send(ping(1472), 1);
        send(ping(8972), 1);                                             // 9000-byte MTU
        send(ip(DMAC, DIP, 17, 100, 16'd40000, 16'd7, 16'h0000), 1);     // UDP echo
        send(ip(DMAC, DIP, 17, 0,   16'd40001, 16'd7, 16'h4000), 1);
        // checksum carry corner cases
        for (int i = 0; i < 64; i++) begin
            f = ping(2); f[42] = 0; f[43] = 0; f[36] = 0; f[37] = 0;
            f[38] = 8'hF0 + i; f[39] = 8'hF8; f[40] = 0; f[41] = 0;
            cc = csum(f, 34, 44); f[36] = cc[15:8]; f[37] = cc[7:0];
            send(f, 1);
        end
        settle(20000);
        if (exp_q.size()) begin errors++; $display("ERROR: %0d replies missing (directed)", exp_q.size()); exp_q.delete(); end
        r0 = replies;
        // refused: nothing may come back
        send(arp(48'hFFFFFFFFFFFF, 1, DIP + 1), 0);
        send(arp(48'hFFFFFFFFFFFF, 1, DIP ^ 32'h01000000), 0);
        send(arp(DMAC, 2, DIP), 0);
        send(ip(DMAC, DIP + 1, 1, 56, 16'h0800, 0, 0), 0);               // other IP
        send(ip(DMAC, DIP ^ 32'h00010000, 1, 56, 16'h0800, 0, 0), 0);
        send(ip(DMAC ^ 1, DIP, 1, 56, 16'h0800, 0, 0), 0);               // other MAC
        send(ip(48'hFFFFFFFFFFFF, DIP, 1, 56, 16'h0800, 0, 0), 0);       // broadcast MAC
        send(ip(DMAC, DIP, 1, 56, 16'h0000, 0, 0), 0);                   // echo reply
        send(ip(DMAC, DIP, 1, 56, 16'h0800, 0, 16'h2000), 0);            // first fragment
        send(ip(DMAC, DIP, 1, 56, 16'h0800, 0, 16'h0010), 0);            // later fragment
        send(ip(DMAC, DIP, 17, 56, 16'd40000, 16'd8, 0), 0);             // other UDP port
        send(ip(DMAC, DIP, 17, 56, 16'd7, 16'd7, 0), 0);                 // echo loop
        send(ip(DMAC, DIP, 6, 56, 16'd40000, 16'd7, 0), 0);              // TCP
        f = arp(48'hFFFFFFFFFFFF, 1, DIP); f[6] = 8'h01; send(f, 0);     // multicast source
        f = ping(56); f[14] = 8'h46; send(f, 0);                         // IP options
        f = ping(56); f[12] = 8'h86; f[13] = 8'hDD; send(f, 0);          // IPv6
        for (int i = 14; i <= 34; i += 4) begin f = ping(0); while (f.size() > i) f.pop_back(); send(f, 0); end  // short (padded by the MAC)
        settle(2000);
        // bad FCS: a ping with a flipped payload bit
        fork
            send(ping(200), 0);
            begin
                wait (h2d_c[0] && h2d_d[7:0] == 8'hFB);
                repeat (8) @(negedge tclk);
                corrupt = 1; @(negedge tclk); corrupt = 0;
            end
        join
        settle(2000);
        if (replies != r0) begin errors++; $display("ERROR: replied to refused frames"); end
        if (st[63:32] != 1) begin errors++; $display("ERROR: bad FCS counter %0d", st[63:32]); end
        // line rate: random sizes, then minimum frames, back to back
        r0 = replies;  t0 = $realtime;
        for (n = 0; n < 400; n++) send(ping($urandom_range(0, 1472)), 1);
        for (n = 0; n < 1500; n++) send(ping($urandom_range(0, 26)), 1);
        settle(60000);
        $display("bursts: sent 1900, replies %0d, overflow %0d", replies - r0, st[127:96]);
        if (exp_q.size() || st[127:96] != 0) begin errors++; $display("ERROR: %0d replies missing (burst)", exp_q.size()); end
        settle(200);
        $display("counters: rx_good %0d bad_fcs %0d bad_frame %0d ovf %0d arp %0d ping %0d udp %0d tx %0d; replies seen %0d",
            st[31:0], st[63:32], st[95:64], st[127:96], st[159:128], st[191:160], st[223:192], st[255:224], replies);
        if (st[255:224] != replies || st[159:128] + st[191:160] + st[223:192] != replies) begin errors++; $display("ERROR: counters"); end
        if (errors == 0) $display("PASS"); else $display("FAIL, %0d errors", errors);
        $finish;
    end
endmodule
