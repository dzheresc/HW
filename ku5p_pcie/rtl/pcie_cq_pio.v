// Minimal PCIe target for the UltraScale+ integrated block (pcie4_uscale_plus),
// Completer Request (CQ) / Completer Completion (CC) AXI-Stream interfaces,
// straddle off, DWORD-aligned mode. DATA_W may be 64, 128 or 256.
//
// Same behaviour as the K7 pcie_pio: 1-DW memory reads/writes become one
// register bus access; reads of any other length get an Unsupported Request
// completion; writes of other lengths and anything else are dropped (but
// non-posted ones still get a UR completion so the host does not time out).
// One request at a time: CQ is stalled while a completion is pending.
//
// CQ descriptor (PG213): DW0-1 address (byte address in [63:2] of the
// 64-bit field), DW2 [10:0] dword count, [14:11] request type,
// [31:16] requester ID, DW3 [7:0] tag, [18:16] BAR id, [27:25] TC,
// [30:28] attr. Payload starts at DW4, little-endian (no byte swap).
// tuser[3:0] first BE, [7:4] last BE (for DATA_W < 512).
`default_nettype none
module pcie_cq_pio #(
  parameter DATA_W = 256
) (
  input  wire                clk,
  input  wire                rst,

  input  wire [DATA_W-1:0]   cq_tdata,
  input  wire                cq_tlast,
  input  wire                cq_tvalid,
  output wire                cq_tready,
  input  wire [87:0]         cq_tuser,

  output reg  [DATA_W-1:0]   cc_tdata,
  output reg  [DATA_W/32-1:0] cc_tkeep,
  output reg                 cc_tlast,
  output reg                 cc_tvalid,
  input  wire                cc_tready,

  // register bus: req is a one-cycle strobe, ack comes some cycles later
  output reg                 bus_req,
  output reg                 bus_we,
  output reg  [11:2]         bus_addr,
  output reg  [31:0]         bus_wdata,
  input  wire                bus_ack,
  input  wire [31:0]         bus_rdata
);
  localparam NDW   = DATA_W / 32;            // DWs per beat
  localparam CBEAT = (4 + NDW - 1) / NDW;    // beats of a completion (3 hdr + 1 data DW)

  localparam S_RX = 3'd0, S_DEC = 3'd1, S_WAIT = 3'd2, S_CPL = 3'd3, S_WWAIT = 3'd4;
  reg [2:0] st;

  // first five DWs of the request and the first BE
  reg [31:0] dw0, dw1, dw2, dw3, dw4;
  reg [3:0]  fbe;
  reg [2:0]  beat;     // index of the current CQ beat (saturates)
  reg [31:0] rdata;
  reg        ur;
  reg [1:0]  cbeat;

  wire [10:0] dwcnt  = dw2[10:0];
  wire [3:0]  rtype  = dw2[14:11];
  wire        is_mrd = (rtype == 4'b0000);
  wire        is_mwr = (rtype == 4'b0001);
  // non-posted types other than MRd: I/O, locked read, atomics, ...; they get UR
  wire        is_np  = (rtype == 4'b0010) || (rtype == 4'b0011) || (rtype == 4'b0111) ||
                       (rtype == 4'b0100) || (rtype == 4'b0101) || (rtype == 4'b0110) || is_mrd;

  assign cq_tready = (st == S_RX);

  // byte count and lower address for a 1-DW read (PCIe base spec table 2-21)
  reg [2:0] bcnt;
  reg [1:0] lad;
  always @* begin
    casez (fbe)
      4'b1??1: bcnt = 3'd4;
      4'b01?1: bcnt = 3'd3;
      4'b1?10: bcnt = 3'd3;
      4'b0011, 4'b0110, 4'b1100: bcnt = 3'd2;
      default: bcnt = 3'd1;
    endcase
    casez (fbe)
      4'b???1: lad = 2'd0;
      4'b??10: lad = 2'd1;
      4'b?100: lad = 2'd2;
      4'b1000: lad = 2'd3;
      default: lad = 2'd0;
    endcase
  end

  // CC descriptor (PG213 "Completer Completion Descriptor Format")
  wire [6:0]  low_addr = ur ? 7'd0 : {dw0[6:2], lad};
  wire [12:0] c_bytes  = ur ? 13'd0 : {10'd0, bcnt};
  wire [31:0] c_dw0 = {3'b000, c_bytes, 6'd0, dw0[1:0], 1'b0, low_addr};
  wire [31:0] c_dw1 = {dw2[31:16], 1'b0, 1'b0, ur ? 3'b001 : 3'b000, ur ? 11'd0 : 11'd1};
  wire [31:0] c_dw2 = {1'b0, dw3[30:28], dw3[27:25], 1'b0, 8'd0, dw3[15:8], dw3[7:0]};
  wire [127:0] cpl  = {rdata, c_dw2, c_dw1, c_dw0};

  integer j;
  always @(posedge clk) begin
    bus_req <= 1'b0;
    if (rst) begin
      st <= S_RX;
      beat <= 3'd0;
      cc_tvalid <= 1'b0;
      cc_tlast <= 1'b0;
    end else begin
      case (st)
        S_RX: if (cq_tvalid) begin
          if (beat == 0 / NDW) dw0 <= cq_tdata[32 * (0 % NDW) +: 32];
          if (beat == 1 / NDW) dw1 <= cq_tdata[32 * (1 % NDW) +: 32];
          if (beat == 2 / NDW) dw2 <= cq_tdata[32 * (2 % NDW) +: 32];
          if (beat == 3 / NDW) dw3 <= cq_tdata[32 * (3 % NDW) +: 32];
          if (beat == 4 / NDW) dw4 <= cq_tdata[32 * (4 % NDW) +: 32];
          if (beat == 3'd0) fbe <= cq_tuser[3:0];
          if (beat != 3'd7) beat <= beat + 3'd1;
          if (cq_tlast) begin
            beat <= 3'd0;
            st <= S_DEC;
          end
        end
        S_DEC: begin
          bus_addr  <= dw0[11:2];
          bus_wdata <= dw4;
          ur        <= !(is_mrd && dwcnt == 11'd1);
          rdata     <= 32'd0;
          if (is_mwr) begin
            if (dwcnt == 11'd1 && fbe != 4'b0000) begin
              bus_req <= 1'b1;
              bus_we  <= 1'b1;
              st <= S_WWAIT;
            end else
              st <= S_RX;
          end else if (is_mrd && dwcnt == 11'd1) begin
            bus_req <= 1'b1;
            bus_we  <= 1'b0;
            st <= S_WAIT;
          end else if (is_np) begin
            cbeat <= 2'd0;
            st <= S_CPL;
          end else
            st <= S_RX;
        end
        S_WWAIT: if (bus_ack) st <= S_RX;
        S_WAIT: if (bus_ack) begin
          rdata <= bus_rdata;
          cbeat <= 2'd0;
          st <= S_CPL;
        end
        S_CPL: if (!cc_tvalid || cc_tready) begin
          if (cc_tvalid && cc_tlast) begin
            cc_tvalid <= 1'b0;
            cc_tlast  <= 1'b0;
            st <= S_RX;
          end else begin
            cc_tdata <= {DATA_W{1'b0}};
            cc_tkeep <= {NDW{1'b0}};
            for (j = 0; j < NDW && j < 4; j = j + 1)
              if (cbeat * NDW + j < 4) begin
                cc_tdata[32 * j +: 32] <= cpl[32 * (cbeat * NDW + j) +: 32];
                cc_tkeep[j] <= (cbeat * NDW + j < (ur ? 3 : 4));
              end
            cc_tlast  <= (cbeat == CBEAT - 1);
            cc_tvalid <= 1'b1;
            cbeat <= cbeat + 2'd1;
          end
        end
        default: st <= S_RX;
      endcase
    end
  end
endmodule
`default_nettype wire
