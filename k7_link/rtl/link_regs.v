// BAR0 registers of one k7_link port (read-only, user_clk). Byte offsets from the port base
// (port A 0x200, port B 0x240):
//   +00 RX_GOOD  +04 RX_BAD_FCS  +08 RX_BAD_FRAME (includes bad FCS)  +0C RX_FIFO_OVERFLOW
//   +10 ARP_REPLIES  +14 PING_REPLIES  +18 UDP_REPLIES  +1C TX_FRAMES
//   +20 IP  +24 MAC_HI  +28 MAC_LO  +2C LINK [0] up
`default_nettype none
module link_regs #(
    parameter [47:0] MAC = 48'd0,
    parameter [31:0] IP  = 32'd0
) (
    input  wire        clk,
    input  wire        req,
    input  wire [5:2]  addr,
    output reg  [31:0] rdata,
    input  wire [255:0] st,
    input  wire        st_tgl,
    input  wire        link           // any clock domain
);
    (* ASYNC_REG = "TRUE" *) reg [2:0] t = 3'd0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ls = 2'd0;
    reg [255:0] s = 256'd0;
    always @(posedge clk) begin
        t  <= {t[1:0], st_tgl};
        ls <= {ls[0], link};
        if (t[2] != t[1]) s <= st;
        if (req) case (addr)
            4'h8: rdata <= IP;
            4'h9: rdata <= {16'd0, MAC[47:32]};
            4'hA: rdata <= MAC[31:0];
            4'hB: rdata <= {31'd0, ls[1]};
            default: rdata <= addr[5] ? 32'd0 : s[32*addr[4:2] +: 32];
        endcase
    end
endmodule
`default_nettype wire
