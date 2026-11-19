// Minimal PCIe target for the 7 Series integrated block, 64-bit AXI-Stream.
// Handles 3DW memory reads/writes to BAR0 with length 1 (32-bit MMIO).
// Reads of any other length get an Unsupported Request completion.
// Everything else (messages, 4DW requests, ...) is dropped.
// One request at a time: rx is stalled while a completion is pending.
`default_nettype none
module pcie_pio (
  input  wire        clk,
  input  wire        rst,

  input  wire [63:0] rx_tdata,
  input  wire [7:0]  rx_tkeep,
  input  wire        rx_tlast,
  input  wire        rx_tvalid,
  output wire        rx_tready,
  input  wire [21:0] rx_tuser,

  output reg  [63:0] tx_tdata,
  output reg  [7:0]  tx_tkeep,
  output reg         tx_tlast,
  output reg         tx_tvalid,
  input  wire        tx_tready,

  input  wire [15:0] completer_id,

  // register bus: req is a one-cycle strobe, ack comes some cycles later
  output reg         bus_req,
  output reg         bus_we,
  output reg  [11:2] bus_addr,
  output reg  [31:0] bus_wdata,
  input  wire        bus_ack,
  input  wire [31:0] bus_rdata
);
  localparam S_HDR0 = 3'd0, S_HDR1 = 3'd1, S_DROP = 3'd2, S_WAIT = 3'd3,
             S_CPL0 = 3'd4, S_CPL1 = 3'd5, S_WWAIT = 3'd6, S_CPL2 = 3'd7;
  reg [2:0] st;

  reg [31:0] dw0, dw1;
  reg [31:0] rdata;
  reg        ur;            // unsupported read (length != 1)

  function [31:0] bswap(input [31:0] x); bswap = {x[7:0], x[15:8], x[23:16], x[31:24]}; endfunction

  wire [2:0] fmt   = dw0[31:29];
  wire [4:0] typ   = dw0[28:24];
  wire [9:0] len   = dw0[9:0];
  wire [3:0] fbe   = dw1[3:0];

  assign rx_tready = (st == S_HDR0) || (st == S_HDR1) || (st == S_DROP);

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

  reg [6:0]  low_addr;
  wire [31:0] c_dw0 = {ur ? 3'b000 : 3'b010, 5'b01010, 1'b0, dw0[22:20], 4'b0, 1'b0, 1'b0,
                       dw0[13:12], 2'b00, ur ? 10'd0 : 10'd1};
  wire [31:0] c_dw1 = {completer_id, ur ? 3'b001 : 3'b000, 1'b0, ur ? 12'd4 : {9'd0, bcnt}};
  wire [31:0] c_dw2 = {dw1[31:16], dw1[15:8], 1'b0, low_addr};

  always @(posedge clk) begin
    bus_req <= 1'b0;
    if (rst) begin
      st <= S_HDR0;
      tx_tvalid <= 1'b0;
      tx_tlast <= 1'b0;
    end else begin
      case (st)
        S_HDR0: if (rx_tvalid) begin
          dw0 <= rx_tdata[31:0];
          dw1 <= rx_tdata[63:32];
          st  <= rx_tlast ? S_HDR0 : S_HDR1;
        end
        S_HDR1: if (rx_tvalid) begin
          // 3DW header: DW2 = address, DW3 = first payload DW for writes
          bus_addr  <= rx_tdata[11:2];
          bus_wdata <= bswap(rx_tdata[63:32]);  // payload DWs arrive byte-swapped
          low_addr  <= {rx_tdata[6:2], lad};
          ur        <= (len != 10'd1);
          if (fmt == 3'b010 && typ == 5'b00000) begin          // MWr32
            if (fbe != 4'b0000 && rx_tuser[2]) begin
              bus_req <= 1'b1;
              bus_we  <= 1'b1;
              st <= rx_tlast ? S_WWAIT : S_DROP;  // S_WWAIT/S_DROP: ack is ignored
            end else
              st <= rx_tlast ? S_HDR0 : S_DROP;
          end else if (fmt == 3'b000 && typ == 5'b00000) begin  // MRd32
            if (len == 10'd1) begin
              bus_req <= 1'b1;
              bus_we  <= 1'b0;
              st <= S_WAIT;
            end else begin
              st <= S_CPL0;
            end
          end else begin
            st <= rx_tlast ? S_HDR0 : S_DROP;
          end
        end
        S_DROP: if (rx_tvalid && rx_tlast) st <= S_HDR0;
        S_WWAIT: if (bus_ack) st <= S_HDR0;
        S_WAIT: if (bus_ack) begin
          rdata <= bus_rdata;
          st <= S_CPL0;
        end
        S_CPL0: if (!tx_tvalid || tx_tready) begin
          tx_tdata  <= {c_dw1, c_dw0};
          tx_tkeep  <= 8'hFF;
          tx_tlast  <= 1'b0;
          tx_tvalid <= 1'b1;
          st <= S_CPL1;
        end
        S_CPL1: if (tx_tready) begin
          tx_tdata  <= {bswap(rdata), c_dw2};
          tx_tkeep  <= ur ? 8'h0F : 8'hFF;
          tx_tlast  <= 1'b1;
          st <= S_CPL2;
        end
        S_CPL2: if (tx_tready) begin
          tx_tvalid <= 1'b0;
          tx_tlast  <= 1'b0;
          st <= S_HDR0;
        end
      endcase
    end
  end
endmodule
`default_nettype wire
