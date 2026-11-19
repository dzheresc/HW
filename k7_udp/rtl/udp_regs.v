// BAR0 registers of the UDP counter sender (k7_udp), user_clk domain.
//
//   0x080 UDP_CTRL   RW  [0] enable (reset 1)
//   0x084 MAC_HI     RW  [15:0] local MAC bits 47:32   (reset 0x024B   -> 02:4B:37:00:00:6E)
//   0x088 MAC_LO     RW  local MAC bits 31:0           (reset 0x3700006E)
//   0x08C LOCAL_IP   RW  (reset 0xC0A8006E 192.168.0.110)
//   0x090 DEST_IP    RW  (reset 0xC0A800D7 192.168.0.215)
//   0x094 GATEWAY_IP RW  (reset 0xC0A80001 192.168.0.1)
//   0x098 SUBNET     RW  (reset 0xFFFFFE00 /23)
//   0x09C PORTS      RW  [31:16] UDP source port, [15:0] destination port (reset 5000/5000)
//   0x0A0 PERIOD     RW  156.25 MHz cycles between datagrams (reset 156250000 = 1 s, min 1000)
//   0x0A4 COUNT_LO   RO  datagrams sent (= next counter value), bits 31:0
//   0x0A8 COUNT_HI   RO  bits 63:32
//   0x0AC UDP_STAT   RO  [15:0] ARP resolution failures, [31:16] good frames received on SFP A
// IP addresses are written as 32-bit numbers, first octet in bits 31:24.
// A write to 0x080..0x0A0 takes effect in the TX clock domain a few cycles later;
// read-only values update once per PERIOD (mid-period).
`default_nettype none
module udp_regs (
    input  wire        clk,
    input  wire        rst,
    input  wire        req,
    input  wire        we,
    input  wire [11:2] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    output reg         cfg_tgl = 1'b0,
    output reg         cfg_enable = 1'b1,
    output reg  [47:0] cfg_local_mac = 48'h02_4B_37_00_00_6E,
    output reg  [31:0] cfg_local_ip = 32'hC0A8_006E,
    output reg  [31:0] cfg_dest_ip = 32'hC0A8_00D7,
    output reg  [31:0] cfg_gateway_ip = 32'hC0A8_0001,
    output reg  [31:0] cfg_subnet_mask = 32'hFFFF_FE00,
    output reg  [15:0] cfg_src_port = 16'd5000,
    output reg  [15:0] cfg_dst_port = 16'd5000,
    output reg  [31:0] cfg_period = 32'd156_250_000,

    // from the TX clock domain, stable around st_tgl flips
    input  wire [63:0] st_count,
    input  wire [15:0] st_arp_fail,
    input  wire [15:0] st_rx_frames,
    input  wire        st_tgl
);
    (* ASYNC_REG = "TRUE" *) reg [2:0] st_tgl_s = 3'b000;
    reg [63:0] count_u = 64'd0;
    reg [31:0] stat_u = 32'd0;
    reg        wr_d = 1'b0;

    wire wr = req && we && addr[11:7] == 5'b00001;

    always @(posedge clk) begin
        st_tgl_s <= {st_tgl_s[1:0], st_tgl};
        if (st_tgl_s[2] != st_tgl_s[1]) begin
            count_u <= st_count;
            stat_u  <= {st_rx_frames, st_arp_fail};
        end

        if (req) case (addr[6:2])
            5'h00: rdata <= {31'd0, cfg_enable};
            5'h01: rdata <= {16'd0, cfg_local_mac[47:32]};
            5'h02: rdata <= cfg_local_mac[31:0];
            5'h03: rdata <= cfg_local_ip;
            5'h04: rdata <= cfg_dest_ip;
            5'h05: rdata <= cfg_gateway_ip;
            5'h06: rdata <= cfg_subnet_mask;
            5'h07: rdata <= {cfg_src_port, cfg_dst_port};
            5'h08: rdata <= cfg_period;
            5'h09: rdata <= count_u[31:0];
            5'h0A: rdata <= count_u[63:32];
            5'h0B: rdata <= stat_u;
            default: rdata <= 32'd0;
        endcase

        // config registers change on the write edge; the toggle flips one cycle later
        wr_d <= wr && addr[6:2] <= 5'h08;
        if (wr_d) cfg_tgl <= ~cfg_tgl;
        if (wr) case (addr[6:2])
            5'h00: cfg_enable <= wdata[0];
            5'h01: cfg_local_mac[47:32] <= wdata[15:0];
            5'h02: cfg_local_mac[31:0] <= wdata;
            5'h03: cfg_local_ip <= wdata;
            5'h04: cfg_dest_ip <= wdata;
            5'h05: cfg_gateway_ip <= wdata;
            5'h06: cfg_subnet_mask <= wdata;
            5'h07: begin cfg_src_port <= wdata[31:16]; cfg_dst_port <= wdata[15:0]; end
            5'h08: cfg_period <= wdata;
            default: ;
        endcase
    end
endmodule
`default_nettype wire
