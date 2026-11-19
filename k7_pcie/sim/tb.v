`timescale 1ns/1ps
module flash_model(input sck, input cs_n, input mosi, output reg miso);
  reg [7:0] cmd; reg [31:0] addr; integer bitc; reg [7:0] sh; reg [7:0] outb;
  initial miso = 1'bz;
  always @(negedge cs_n) begin bitc = 0; end
  always @(posedge cs_n) miso <= 1'bz;
  always @(posedge sck) if (!cs_n) begin
    sh = {sh[6:0], mosi}; bitc = bitc + 1;
    if (bitc == 8) cmd = sh;
    if (bitc > 8 && bitc <= 32) addr = {addr[23:0], mosi};
  end
  always @(negedge sck) if (!cs_n) begin
    if (cmd == 8'h9F && bitc >= 8) begin
      case ((bitc-8)/8) 0: outb = 8'hEF; 1: outb = 8'h40; 2: outb = 8'h19; default: outb = 8'h00; endcase
      miso <= #7 outb[7 - ((bitc-8)%8)];
    end else if (cmd == 8'h03 && bitc >= 32) begin
      outb = addr[7:0] + (bitc-32)/8;
      miso <= #7 outb[7 - ((bitc-32)%8)];
    end
  end
endmodule

module tb;
  reg clk = 0; always #4 clk = ~clk;
  reg rst = 1;
  reg [63:0] rx_tdata; reg [7:0] rx_tkeep; reg rx_tlast=0, rx_tvalid=0; wire rx_tready;
  wire [63:0] tx_tdata; wire [7:0] tx_tkeep; wire tx_tlast, tx_tvalid;
  wire req, we, ack; wire [11:2] addr; wire [31:0] wdata, rdata;
  wire sck, cs_n, mosi, miso, busy;
  pcie_pio pio(.clk(clk), .rst(rst), .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tlast(rx_tlast),
    .rx_tvalid(rx_tvalid), .rx_tready(rx_tready), .rx_tuser(22'h4),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(1'b1),
    .completer_id(16'h0100), .bus_req(req), .bus_we(we), .bus_addr(addr), .bus_wdata(wdata),
    .bus_ack(ack), .bus_rdata(rdata));
  spi_regs regs(.clk(clk), .rst(rst), .req(req), .we(we), .addr(addr), .wdata(wdata), .ack(ack), .rdata(rdata),
    .link_status(32'h1234), .spi_sck(sck), .spi_cs_n(cs_n), .spi_mosi(mosi), .spi_miso(miso), .busy_o(busy));
  flash_model fl(.sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso));

  reg [31:0] cpl [0:3]; integer ci = 0;
  always @(posedge clk) if (tx_tvalid) begin
    if (ci == 0) begin cpl[0] = tx_tdata[31:0]; cpl[1] = tx_tdata[63:32]; ci = 1; end
    else begin cpl[2] = tx_tdata[31:0]; cpl[3] = tx_tdata[63:32]; ci = 0; end
  end

  task beat(input [63:0] d, input last); begin
    rx_tdata <= d; rx_tkeep <= 8'hFF; rx_tlast <= last; rx_tvalid <= 1;
    @(posedge clk); while (!rx_tready) @(posedge clk);
    rx_tvalid <= 0; rx_tlast <= 0;
  end endtask
  task mwr(input [31:0] a, input [31:0] d); begin
    beat({32'h0100_00_0F, 32'h4000_0001}, 0);
    beat({d[7:0],d[15:8],d[23:16],d[31:24], a}, 1);
    repeat (4) @(posedge clk);
  end endtask
  task mrd(input [31:0] a, output [31:0] d); begin
    beat({32'h0100_07_0F, 32'h0000_0001}, 0);
    beat({32'h0, a}, 1);
    @(posedge clk); while (!(tx_tvalid && tx_tlast)) @(posedge clk);
    @(posedge clk);
    d = {cpl[3][7:0],cpl[3][15:8],cpl[3][23:16],cpl[3][31:24]};
  end endtask

  reg [31:0] v; integer i;
  initial begin
    repeat (10) @(posedge clk); rst = 0;
    mrd(32'hF000_0000, v); $display("ID(raw) %h cpl %h %h %h", v, cpl[0], cpl[1], cpl[2]);
    mwr(32'hF000_0014, 32'hCAFEF00D); mrd(32'hF000_0014, v); $display("SCRATCH %h", v);
    while (busy) @(posedge clk);
    // JEDEC ID
    mwr(32'hF000_0400, 32'h0000009F); mwr(32'hF000_0010, 4);
    v = 1; while (v[0]) mrd(32'hF000_0008, v);
    mrd(32'hF000_0800, v); $display("JEDEC rx %h (expect 1940EFxx)", v);
    // read 03 addr 0x000010, 8 bytes, split into 2 transfers with CS held
    mwr(32'hF000_0400, 32'h10000003); mwr(32'hF000_0010, 32'h8000_0008);
    v = 1; while (v[0]) mrd(32'hF000_0008, v);
    mrd(32'hF000_0804, v); $display("READ a %h (expect 13121110) status cs=%0d", v, 0);
    mrd(32'hF000_0008, v); $display("STATUS %h (expect 2: CS held)", v);
    mwr(32'hF000_0010, 4);
    v = 1; while (v[0]) mrd(32'hF000_0008, v);
    mrd(32'hF000_0800, v); $display("READ b %h (expect 17161514) status %h", v, v);
    mrd(32'hF000_0008, v); $display("STATUS %h (expect 0)", v);
    mrd(32'hF000_0018, v); $display("LINK %h", v);
    // a 2-DW read must get a UR completion
    beat({32'h0100_08_FF, 32'h0000_0002}, 0); beat({32'h0, 32'hF000_0000}, 1);
    @(posedge clk); while (!(tx_tvalid && tx_tlast)) @(posedge clk); @(posedge clk);
    $display("UR cpl %h %h %h", cpl[0], cpl[1], cpl[2]);
    $finish;
  end
endmodule
