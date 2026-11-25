// Testbench: pcie_cq_pio + spi_regs + a tiny SPI flash model.
// iverilog -g2005 -DDW=256 -o tb sim/tb.v rtl/pcie_cq_pio.v rtl/spi_regs.v && vvp tb
`timescale 1ns/1ps
`ifndef DW
`define DW 256
`endif
module flash_model(input sck, input cs_n, input mosi, output reg miso);
  reg [7:0] cmd; reg [31:0] addr; integer bitc; reg [7:0] sh; reg [7:0] outb;
  initial miso = 1'bz;
  always @(negedge cs_n) begin bitc = 0; end
  always @(posedge cs_n) miso <= 1'bz;
  always @(posedge sck) if (!cs_n) begin
    sh = {sh[6:0], mosi}; bitc = bitc + 1;
    if (bitc == 8) cmd = sh;
    if (bitc > 8 && bitc <= 40) addr = {addr[30:0], mosi};
  end
  always @(negedge sck) if (!cs_n) begin
    if (cmd == 8'h9F && bitc >= 8) begin
      case ((bitc-8)/8) 0: outb = 8'h20; 1: outb = 8'hBB; 2: outb = 8'h19; default: outb = 8'h00; endcase
      miso <= #7 outb[7 - ((bitc-8)%8)];
    end else if (cmd == 8'h13 && bitc >= 40) begin   // 4-byte read
      outb = addr[7:0] + (bitc-40)/8;
      miso <= #7 outb[7 - ((bitc-40)%8)];
    end
  end
endmodule

module tb;
  localparam DATA_W = `DW, NDW = DATA_W / 32;
  reg clk = 0; always #2 clk = ~clk;   // 250 MHz
  reg rst = 1;
  reg [DATA_W-1:0] cq_tdata = 0; reg cq_tlast = 0, cq_tvalid = 0; reg [87:0] cq_tuser = 0;
  wire cq_tready;
  wire [DATA_W-1:0] cc_tdata; wire [NDW-1:0] cc_tkeep; wire cc_tlast, cc_tvalid;
  reg cc_tready = 1;
  wire req, we, ack; wire [2:0] pst; wire [31:0] pd0, pd2; wire [11:2] addr; wire [31:0] wdata, rdata;
  wire sck, cs_n, mosi, miso, busy, sel;
  pcie_cq_pio #(.DATA_W(DATA_W)) pio(.clk(clk), .rst(rst),
    .cq_tdata(cq_tdata), .cq_tlast(cq_tlast), .cq_tvalid(cq_tvalid), .cq_tready(cq_tready), .cq_tuser(cq_tuser),
    .cc_tdata(cc_tdata), .cc_tkeep(cc_tkeep), .cc_tlast(cc_tlast), .cc_tvalid(cc_tvalid), .cc_tready(cc_tready),
    .bus_req(req), .bus_we(we), .bus_addr(addr), .bus_wdata(wdata), .bus_ack(ack), .bus_rdata(rdata), .dbg_state(pst), .dbg_dw0(pd0), .dbg_dw2(pd2));
  spi_regs #(.ID(32'h4B555043), .VERSION(32'h00020000), .FEAT(32'h1), .HALF_RESET(8'd8)) regs(
    .clk(clk), .rst(rst), .req(req), .we(we), .addr(addr), .wdata(wdata), .ack(ack), .rdata(rdata),
    .link_status(32'h0000B21A), .spi_sck(sck), .spi_cs_n(cs_n), .spi_mosi(mosi), .spi_miso(miso),
    .spi_sel(sel), .busy_o(busy), .dbg0(32'd0), .dbg1(32'd0), .dbg2(32'd0));
  flash_model fl(.sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso));

  // collect completion DWs (tkeep-qualified) in order
  reg [31:0] cpl [0:15]; integer cn = 0; reg cdone = 0;
  integer k;
  always @(posedge clk) if (cc_tvalid && cc_tready) begin
    for (k = 0; k < NDW; k = k + 1) if (cc_tkeep[k]) begin cpl[cn] = cc_tdata[32*k +: 32]; cn = cn + 1; end
    if (cc_tlast) cdone = 1;
  end

  // send a request: 4 descriptor DWs + payload DWs, packed NDW per beat
  reg [31:0] pkt [0:15];
  task send(input integer ndws, input [3:0] fbe); integer b, i, nb; begin
    nb = (ndws + NDW - 1) / NDW;
    @(negedge clk);
    for (b = 0; b < nb; b = b + 1) begin
      cq_tdata = 0;
      for (i = 0; i < NDW; i = i + 1) if (b*NDW + i < ndws) cq_tdata[32*i +: 32] = pkt[b*NDW + i];
      cq_tuser = 0; cq_tuser[3:0] = fbe; cq_tuser[40] = (b == 0);
      cq_tlast = (b == nb - 1); cq_tvalid = 1;
      @(posedge clk); while (!cq_tready) @(posedge clk);
      @(negedge clk);
    end
    cq_tvalid = 0; cq_tlast = 0;
  end endtask
  task desc(input [3:0] typ, input [31:0] a, input [10:0] len, input [7:0] tag); begin
    pkt[0] = {a[31:2], 2'b00}; pkt[1] = 32'h0;
    pkt[2] = {16'h00A0, 1'b0, typ, len};
    pkt[3] = {1'b0, 3'b000, 3'b000, 6'd12, 3'b000, 8'h00, tag};
  end endtask
  task mwr(input [31:0] a, input [31:0] d); begin
    desc(4'b0001, 32'hF7D00000 + a, 11'd1, 8'h00); pkt[4] = d; send(5, 4'hF);
    repeat (4) @(posedge clk);
  end endtask
  task mrd(input [31:0] a, output [31:0] d); begin
    cn = 0; cdone = 0;
    desc(4'b0000, 32'hF7D00000 + a, 11'd1, 8'h5A); send(4, 4'hF);
    while (!cdone) @(posedge clk);
    if (cn != 4) begin $display("FAIL: completion has %0d DWs", cn); $finish; end
    if (cpl[0][28:16] != 13'd4 || cpl[1][10:0] != 11'd1 || cpl[1][13:11] != 3'b000 ||
        cpl[1][31:16] != 16'h00A0 || cpl[2][7:0] != 8'h5A || cpl[0][6:0] != a[6:0]) begin
      $display("FAIL: bad CC descriptor %08x %08x %08x", cpl[0], cpl[1], cpl[2]); $finish;
    end
    d = cpl[3];
  end endtask

  reg [31:0] v; integer errors = 0, t;
  task expect(input [31:0] got, input [31:0] want, input [8*24-1:0] what); begin
    if (got !== want) begin $display("FAIL %0s: got %08x want %08x", what, got, want); errors = errors + 1; end
    else $display("ok   %0s = %08x", what, got);
  end endtask

  initial begin
    repeat (300) @(posedge clk); rst = 0;
    repeat (600) @(posedge clk);   // init dummy clocks
    mrd(32'h000, v); expect(v, 32'h4B555043, "ID");
    mrd(32'h004, v); expect(v, 32'h00020000, "VERSION");
    mrd(32'h00C, v); expect(v, 32'h00000008, "CTRL reset");
    mrd(32'h020, v); expect(v, 32'h00000001, "FEAT");
    mrd(32'h018, v); expect(v, 32'h0000B21A, "LINK");
    mwr(32'h014, 32'hDEADBEEF);
    mrd(32'h014, v); expect(v, 32'hDEADBEEF, "SCRATCH");
    mwr(32'h00C, 32'h00000104);
    mrd(32'h00C, v); expect(v, 32'h00000104, "CTRL sel=1 half=4");
    mwr(32'h00C, 32'h00000004);

    // multi-DW read must get UR (3 DWs, status 001, no data)
    cn = 0; cdone = 0;
    desc(4'b0000, 32'hF7D00000, 11'd2, 8'h11); send(4, 4'hF);
    while (!cdone) @(posedge clk);
    if (cn != 3 || cpl[1][13:11] != 3'b001) begin $display("FAIL: UR completion (%0d DWs, %08x)", cn, cpl[1]); errors = errors + 1; end
    else $display("ok   2-DW read -> UR");
    // 2-DW write is dropped; following read still works
    desc(4'b0001, 32'hF7D00014, 11'd2, 8'h00); pkt[4] = 32'h1; pkt[5] = 32'h2; send(6, 4'hF);
    mrd(32'h014, v); expect(v, 32'hDEADBEEF, "SCRATCH after 2-DW wr");

    // JEDEC ID over SPI
    mwr(32'h400, 32'h0000009F);
    mwr(32'h010, 32'h00000004);
    t = 0; v = 1; while (v[0]) begin mrd(32'h008, v); t = t + 1; end
    mrd(32'h800, v); expect(v & 32'hFFFFFF00, 32'h19BB2000, "JEDEC");
    // 4-byte read at 0x00000010, 8 data bytes
    mwr(32'h400, 32'h00000013); mwr(32'h404, 32'h00000010);
    mwr(32'h010, 32'h0000000D);
    v = 1; while (v[0]) begin mrd(32'h008, v); end
    mrd(32'h804, v); expect(v & 32'hFFFFFF00, 32'h12111000, "read bytes 0-2");
    mrd(32'h808, v); expect(v, 32'h16151413, "read bytes 3-6");
    if (errors) $display("FAILED (%0d)", errors); else $display("PASS DATA_W=%0d", DATA_W);
    $finish;
  end
  initial begin #3000000; $display("FAIL: timeout"); $finish; end
endmodule
