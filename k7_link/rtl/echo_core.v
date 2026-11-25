// Reply-only responder for one 10G port (k7_link), 64-bit AXI-Stream in, 64-bit out.
//
// Answers, and nothing else is ever transmitted:
//   ARP request for LOCAL_IP            -> ARP reply
//   ICMP echo request to LOCAL_IP       -> echo reply (any length that fits the FIFOs, jumbo too)
//   UDP to LOCAL_IP port ECHO_PORT      -> same datagram back, ports swapped
// Not answered: other MACs/IPs (a ping must be to our unicast MAC), IP options, fragments,
// UDP whose source port is also ECHO_PORT (no echo loops), any source with a multicast MAC.
//
// How it works: a 6-word delay line. When word 5 (bytes 40..47) of a frame shifts in, the
// whole header is on hand: the verdict is taken and words 0..5 are rewritten in that one
// shift. Later words inherit the verdict. Words of refused frames shift out invisibly, so
// the path runs at one word per clock (line rate) with no buffering of its own.
// Checksums: swapping addresses/ports leaves the IP and UDP sums unchanged; ICMP is
// patched incrementally (type 8 -> 0). The received IP header checksum is not checked
// (the FCS, checked in the MAC, covers the link). TTL is echoed unchanged.
`default_nettype none

// byte n of a word (byte 0 = first on the wire)
`define B(w, n) w[8*(n) +: 8]

module echo_core #(
    parameter [47:0] LOCAL_MAC = 48'h02_4B_37_00_00_6E,
    parameter [31:0] LOCAL_IP  = {8'd192, 8'd168, 8'd0, 8'd110},
    parameter [15:0] ECHO_PORT = 16'd7
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [63:0] s_tdata,
    input  wire [7:0]  s_tkeep,
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire        s_tlast,
    input  wire        s_tuser,
    output wire [63:0] m_tdata,
    output wire [7:0]  m_tkeep,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,
    output wire        m_tuser,
    output reg         ev_arp = 1'b0,   // one pulse per reply accepted into the delay line
    output reg         ev_icmp = 1'b0,
    output reg         ev_udp = 1'b0
);
    // stage 0 = newest word, stage 5 = oldest (output)
    reg [63:0] d0, d1, d2, d3, d4, d5;
    reg [7:0]  k0, k1, k2, k3, k4, k5;
    reg [5:0]  v = 6'd0, l = 6'd0, acc = 6'd0, u = 6'd0;   // valid, last, accepted, tuser
    reg [2:0]  cnt = 3'd0;                                 // index of the next word (stops at 6)
    reg        fr_acc = 1'b0;                              // verdict for words after 5
    reg        mid = 1'b0;                                 // inside a frame

    // Shift when the output word leaves (or is invisible) and either a new word arrives or
    // we are between frames: bubbles only enter between frames, so headers stay contiguous.
    wire out_vis = v[5] & acc[5];
    wire shift   = (m_tready | ~out_vis) & (s_tvalid | ~mid);
    assign s_tready = (m_tready | ~out_vis);
    assign m_tdata  = d5;
    assign m_tkeep  = k5;
    assign m_tlast  = l[5];
    assign m_tuser  = u[5];
    // Offered only in a cycle that can shift, so a word is never taken twice.
    assign m_tvalid = out_vis & (s_tvalid | ~mid);

    // header checks, registered as the words pass (each is used at word 5)
    reg ok_ucast, ok_bcast, ok_src, is_arp, is_ip, ip_hdr, arp_hdr, arp_op, not_frag;
    reg p_icmp, p_udp, ip_dst_hi, ip_dst_lo, icmp_echo, udp_dport, udp_sport_ok, tpa_hi;

    wire [63:0] w = s_tdata;
    wire take = shift & s_tvalid;
    wire tpa_lo = {`B(w,0), `B(w,1)} == LOCAL_IP[15:0];
    wire arp_hit  = (ok_ucast | ok_bcast) & ok_src & is_arp & arp_hdr & arp_op & tpa_hi & tpa_lo;
    wire ip_hit   = ok_ucast & ok_src & is_ip & ip_hdr & not_frag & ip_dst_hi & ip_dst_lo;
    wire icmp_hit = ip_hit & p_icmp & icmp_echo;
    wire udp_hit  = ip_hit & p_udp & udp_dport & udp_sport_ok;
    wire hit      = arp_hit | icmp_hit | udp_hit;

    // words already in the line when word 5 arrives
    wire [63:0] w0 = d4, w1 = d3, w2 = d2, w3 = d1, w4 = d0;
    wire [16:0] csum_add = {1'b0, `B(w4,4), `B(w4,5)} + 17'h00800;
    wire [15:0] csum_new = csum_add[15:0] + {15'd0, csum_add[16]};

    reg [63:0] r0, r1, r2, r3, r4, r5;
    always @(*) begin
        // Ethernet: destination = old source, source = LOCAL_MAC
        r0 = {LOCAL_MAC[39:32], LOCAL_MAC[47:40], `B(w1,3), `B(w1,2), `B(w1,1), `B(w1,0), `B(w0,7), `B(w0,6)};
        r1 = {w1[63:32], LOCAL_MAC[7:0], LOCAL_MAC[15:8], LOCAL_MAC[23:16], LOCAL_MAC[31:24]};
        r2 = w2;  r3 = w3;  r4 = w4;  r5 = w;
        if (is_arp) begin
            // 20..21 oper, 22..27 SHA, 28..31 SPA, 32..37 THA, 38..41 TPA
            `B(r2,5) = 8'h02;
            `B(r2,6) = LOCAL_MAC[47:40];  `B(r2,7) = LOCAL_MAC[39:32];
            `B(r3,0) = LOCAL_MAC[31:24];  `B(r3,1) = LOCAL_MAC[23:16];
            `B(r3,2) = LOCAL_MAC[15:8];   `B(r3,3) = LOCAL_MAC[7:0];
            `B(r3,4) = LOCAL_IP[31:24];   `B(r3,5) = LOCAL_IP[23:16];
            `B(r3,6) = LOCAL_IP[15:8];    `B(r3,7) = LOCAL_IP[7:0];
            `B(r4,0) = `B(w2,6);  `B(r4,1) = `B(w2,7);
            `B(r4,2) = `B(w3,0);  `B(r4,3) = `B(w3,1);  `B(r4,4) = `B(w3,2);  `B(r4,5) = `B(w3,3);
            `B(r4,6) = `B(w3,4);  `B(r4,7) = `B(w3,5);
            `B(r5,0) = `B(w3,6);  `B(r5,1) = `B(w3,7);
        end else begin
            // 26..29 source IP, 30..33 destination IP
            `B(r3,2) = LOCAL_IP[31:24];   `B(r3,3) = LOCAL_IP[23:16];
            `B(r3,4) = LOCAL_IP[15:8];    `B(r3,5) = LOCAL_IP[7:0];
            `B(r3,6) = `B(w3,2);  `B(r3,7) = `B(w3,3);
            `B(r4,0) = `B(w3,4);  `B(r4,1) = `B(w3,5);
            if (p_icmp) begin
                `B(r4,2) = 8'h00;                                  // echo reply
                `B(r4,4) = csum_new[15:8];  `B(r4,5) = csum_new[7:0];
            end else begin
                `B(r4,2) = `B(w4,4);  `B(r4,3) = `B(w4,5);         // swap the ports
                `B(r4,4) = `B(w4,2);  `B(r4,5) = `B(w4,3);
            end
        end
    end

    always @(posedge clk) begin
        ev_arp <= 1'b0;  ev_icmp <= 1'b0;  ev_udp <= 1'b0;
        if (shift) begin
            d5 <= d4;  d4 <= d3;  d3 <= d2;  d2 <= d1;  d1 <= d0;  d0 <= w;
            k5 <= k4;  k4 <= k3;  k3 <= k2;  k2 <= k1;  k1 <= k0;  k0 <= s_tkeep;
            v   <= {v[4:0], s_tvalid};
            l   <= {l[4:0], s_tlast};
            u   <= {u[4:0], s_tuser};
            acc <= {acc[4:0], s_tvalid & fr_acc & (cnt == 3'd6)};
        end
        if (take) begin
            mid <= ~s_tlast;
            cnt <= s_tlast ? 3'd0 : (cnt == 3'd6 ? 3'd6 : cnt + 3'd1);
            case (cnt)
                3'd0: begin
                    ok_ucast <= {`B(w,0),`B(w,1),`B(w,2),`B(w,3),`B(w,4),`B(w,5)} == LOCAL_MAC;
                    ok_bcast <= &w[47:0];
                    ok_src   <= ~w[48];               // source MAC group bit
                end
                3'd1: begin
                    is_arp  <= {`B(w,4),`B(w,5)} == 16'h0806;
                    is_ip   <= {`B(w,4),`B(w,5)} == 16'h0800;
                    ip_hdr  <= `B(w,6) == 8'h45;
                    arp_hdr <= {`B(w,6),`B(w,7)} == 16'h0001;
                end
                3'd2: begin
                    arp_hdr  <= arp_hdr & ({`B(w,0),`B(w,1),`B(w,2),`B(w,3)} == 32'h0800_0604);
                    arp_op   <= {`B(w,4),`B(w,5)} == 16'h0001;
                    not_frag <= ({`B(w,4),`B(w,5)} & 16'h3FFF) == 16'd0;   // MF and offset
                    p_icmp   <= `B(w,7) == 8'd1;
                    p_udp    <= `B(w,7) == 8'd17;
                end
                3'd3: ip_dst_hi <= {`B(w,6),`B(w,7)} == LOCAL_IP[31:16];
                3'd4: begin
                    ip_dst_lo    <= {`B(w,0),`B(w,1)} == LOCAL_IP[15:0];
                    icmp_echo    <= {`B(w,2),`B(w,3)} == 16'h0800;
                    udp_sport_ok <= {`B(w,2),`B(w,3)} != ECHO_PORT;
                    udp_dport    <= {`B(w,4),`B(w,5)} == ECHO_PORT;
                    tpa_hi       <= {`B(w,6),`B(w,7)} == LOCAL_IP[31:16];
                end
                3'd5: begin
                    fr_acc <= hit;
                    if (hit) begin
                        // replace what the plain shift above would have stored
                        d5 <= r0;  d4 <= r1;  d3 <= r2;  d2 <= r3;  d1 <= r4;  d0 <= r5;
                        acc  <= 6'b111111;
                        ev_arp <= arp_hit;  ev_icmp <= icmp_hit;  ev_udp <= udp_hit;
                    end
                end
                default: ;
            endcase
        end
        if (rst) begin
            v <= 6'd0;  acc <= 6'd0;  cnt <= 3'd0;  mid <= 1'b0;  fr_acc <= 1'b0;
        end
    end
endmodule
`undef B
`default_nettype wire
