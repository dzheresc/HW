// Record merge for k7_cap_ab, PCIe user clock: two (meta, data) FIFO read sides -> one,
// for cap_dma's serializer.
//
// A record is one meta entry plus ceil(captured length / 8) data words, and it is passed
// whole: when the merge offers a port's meta entry it locks onto that port until the
// serializer has popped the entry and all its data words. When both ports have a
// record waiting, the port that did not send the previous record goes first
// (round robin per record). No idle cycles: the next record's meta entry is offered in
// the cycle after the last data word of the previous one.
//
// Relies on cap_dma's serializer: it samples m_valid / m_data (IDLE), pops the meta entry
// in the next cycle (H1), then pops exactly ceil(captured length / 8) data words, and
// pops data only while d_valid.
`default_nettype none
module cap_merge (
  input  wire          clk,
  input  wire          rst,

  input  wire [127:0]  m0_data,
  input  wire          m0_valid,
  output wire          m0_pop,
  input  wire [63:0]   d0_data,
  input  wire          d0_valid,
  output wire          d0_pop,

  input  wire [127:0]  m1_data,
  input  wire          m1_valid,
  output wire          m1_pop,
  input  wire [63:0]   d1_data,
  input  wire          d1_valid,
  output wire          d1_pop,

  output wire [127:0]  m_data,
  output wire          m_valid,
  input  wire          m_pop,
  output wire [63:0]   d_data,
  output wire          d_valid,
  input  wire          d_pop
);
  reg        lock = 1'b0;      // a port is selected (its meta entry offered or popped)
  reg        sel_q = 1'b0;
  reg        last = 1'b1;      // port of the previous record
  reg        in_data = 1'b0;   // meta popped, data words outstanding
  reg [11:0] dleft = 0;

  wire pick = (m0_valid && m1_valid) ? ~last : m1_valid;
  wire sel  = lock ? sel_q : pick;

  assign m_data  = sel ? m1_data : m0_data;
  assign m_valid = !in_data && (sel ? m1_valid : m0_valid);
  assign m0_pop  = m_pop && !sel;
  assign m1_pop  = m_pop &&  sel;
  assign d_data  = sel ? d1_data : d0_data;
  assign d_valid = in_data && (sel ? d1_valid : d0_valid);
  assign d0_pop  = d_pop && !sel;
  assign d1_pop  = d_pop &&  sel;

  wire [11:0] words = (m_data[79:64] + 16'd7) >> 3;

  always @(posedge clk) begin
    if (rst) begin
      lock <= 1'b0;  in_data <= 1'b0;  last <= 1'b1;  dleft <= 0;
    end else begin
      if (!lock && (m0_valid || m1_valid)) begin
        lock  <= 1'b1;
        sel_q <= pick;
      end
      if (m_pop) begin
        if (words == 0) begin
          lock <= 1'b0;  last <= sel;
        end else begin
          in_data <= 1'b1;  dleft <= words;
        end
      end
      if (d_pop) begin
        dleft <= dleft - 1'b1;
        if (dleft == 12'd1) begin
          in_data <= 1'b0;  lock <= 1'b0;  last <= sel;
        end
      end
    end
  end
endmodule
`default_nettype wire
