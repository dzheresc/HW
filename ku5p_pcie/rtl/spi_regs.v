// Register block with a buffered single-lane SPI master for the config flash.
// Shared by the K7 (k7_pcie) and KU5P (ku5p_pcie) designs; ID/VERSION/FEAT and
// the reset SCK divider are parameters.
//
// Register map (32-bit words, byte offsets):
//   0x000 ID       RO  ID parameter (K7: 0x4B375043 "K7PC", KU5P: 0x4B555043 "KUPC")
//   0x004 VERSION  RO  VERSION parameter
//   0x008 STATUS   RO  [0] busy  [1] CS asserted
//   0x00C CTRL     RW  [7:0] SCK half period in clk cycles (min 2, reset HALF_RESET)
//                      [8] flash select (0: primary, 1: second flash of a dual
//                      QSPI pair; only writable when FEAT[0] is set)
//   0x010 XFER     WO  [10:0] byte count (1..1024), [31] keep CS asserted after
//                      the transfer (to continue a command in the next one).
//                      Writing XFER starts a transfer; writing it while busy
//                      is ignored.
//   0x014 SCRATCH  RW
//   0x018 LINK     RO  PCIe status (see top.v)
//   0x01C CSREL    WO  any write releases CS (when idle)
//   0x020 FEAT     RO  FEAT parameter: [0] second flash present
//   0x400..0x7FC TXBUF RW  bytes to send, byte i at word i/4 bits [8*(i%4)+:8]
//   0x800..0xBFC RXBUF RO  bytes received, same layout
// SPI mode 0, MSB first, MOSI on D0, MISO on D1, D2/D3 (WP#/HOLD#) held high.
`default_nettype none
module spi_regs #(
  parameter [31:0] ID         = 32'h4B375043,
  parameter [31:0] VERSION    = 32'h00010000,
  parameter [31:0] FEAT       = 32'h00000000,
  parameter [7:0]  HALF_RESET = 8'd4
) (
  input  wire        clk,
  input  wire        rst,

  input  wire        req,
  input  wire        we,
  input  wire [11:2] addr,
  input  wire [31:0] wdata,
  output reg         ack,
  output reg  [31:0] rdata,

  input  wire [31:0] link_status,

  output reg         spi_sck,
  output reg         spi_cs_n,
  output reg         spi_mosi,
  output reg         spi_sel,     // CTRL[8]: which flash CS to drive
  input  wire        spi_miso,
  output wire        busy_o
);
  reg [7:0]  half;
  reg [31:0] scratch;

  reg [31:0] txmem [0:255];
  reg [7:0]  rxb0 [0:255];
  reg [7:0]  rxb1 [0:255];
  reg [7:0]  rxb2 [0:255];
  reg [7:0]  rxb3 [0:255];

  // engine state
  reg        busy;
  reg        keep_cs;
  reg [10:0] nbytes;
  reg [9:0]  idx;
  reg [2:0]  bitn;
  reg        phase;      // 0: SCK low, 1: SCK high
  reg [7:0]  cnt;
  reg [7:0]  sh_tx, sh_rx;
  reg        init_done;
  reg [3:0]  init_cnt;

  assign busy_o = busy | ~init_done;

  // register reads / writes
  always @(posedge clk) begin
    ack <= req;
    if (req && we && addr[11:10] == 2'b01) txmem[addr[9:2]] <= wdata;
    if (req) begin
      case (addr[11:10])
        2'b00: case (addr[9:2])
          8'h00: rdata <= ID;
          8'h01: rdata <= VERSION;
          8'h02: rdata <= {30'd0, ~spi_cs_n, busy_o};
          8'h03: rdata <= {23'd0, spi_sel, half};
          8'h05: rdata <= scratch;
          8'h06: rdata <= link_status;
          8'h08: rdata <= FEAT;
          default: rdata <= 32'd0;
        endcase
        2'b01: rdata <= txmem[addr[9:2]];
        2'b10: rdata <= {rxb3[addr[9:2]], rxb2[addr[9:2]], rxb1[addr[9:2]], rxb0[addr[9:2]]};
        default: rdata <= 32'd0;
      endcase
    end
    if (rst) begin
      half <= HALF_RESET;
      spi_sel <= 1'b0;
      scratch <= 32'd0;
    end else if (req && we && addr[11:10] == 2'b00) begin
      if (addr[9:2] == 8'h03) begin
        half <= (wdata[7:0] < 8'd2) ? 8'd2 : wdata[7:0];
        if (!busy && spi_cs_n) spi_sel <= wdata[8] & FEAT[0];
      end
      if (addr[9:2] == 8'h05) scratch <= wdata;
    end
  end

  wire [31:0] txw = txmem[idx[9:2]];
  wire [7:0]  txbyte = txw[8*idx[1:0] +: 8];

  reg miso_q;
  always @(posedge clk) miso_q <= spi_miso;

  wire start = req && we && addr[11:2] == 10'h004 && !busy && init_done && wdata[10:0] != 11'd0;
  wire csrel = req && we && addr[11:2] == 10'h007 && !busy && init_done;

  always @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
      spi_sck <= 1'b0;
      spi_cs_n <= 1'b1;
      spi_mosi <= 1'b1;
      init_done <= 1'b0;
      init_cnt <= 4'd0;
      cnt <= 8'd0;
      phase <= 1'b0;
    end else if (!init_done) begin
      // STARTUPE2 drops the first USRCCLKO edges after configuration:
      // give it 8 dummy clocks with CS high.
      cnt <= cnt + 8'd1;
      if (cnt == 8'd15) begin
        cnt <= 8'd0;
        spi_sck <= ~spi_sck;
        init_cnt <= init_cnt + 4'd1;
        if (init_cnt == 4'd15) init_done <= 1'b1;
      end
    end else if (!busy) begin
      spi_sck <= 1'b0;
      if (csrel) spi_cs_n <= 1'b1;
      if (start) begin
        busy    <= 1'b1;
        keep_cs <= wdata[31];
        nbytes  <= wdata[10:0];
        idx     <= 10'd0;
        bitn    <= 3'd7;
        phase   <= 1'b0;
        cnt     <= 8'd0;
        spi_cs_n <= 1'b0;
        sh_tx   <= 8'd0;
      end
    end else begin
      // first cycle of a byte: load the shift register
      cnt <= cnt + 8'd1;
      if (phase == 1'b0) begin
        if (cnt == 8'd0) begin
          spi_mosi <= (bitn == 3'd7) ? txbyte[7] : sh_tx[7];
          if (bitn == 3'd7) sh_tx <= txbyte;
        end
        if (cnt == half - 8'd1) begin
          cnt <= 8'd0;
          phase <= 1'b1;
          spi_sck <= 1'b1;
        end
      end else begin
        if (cnt == half - 8'd1) begin
          // sample at the end of the high phase (MISO registered once more)
          sh_rx <= {sh_rx[6:0], miso_q};
          sh_tx <= {sh_tx[6:0], 1'b0};
          cnt <= 8'd0;
          phase <= 1'b0;
          spi_sck <= 1'b0;
          bitn <= bitn - 3'd1;
          if (bitn == 3'd0) begin
            case (idx[1:0])
              2'd0: rxb0[idx[9:2]] <= {sh_rx[6:0], miso_q};
              2'd1: rxb1[idx[9:2]] <= {sh_rx[6:0], miso_q};
              2'd2: rxb2[idx[9:2]] <= {sh_rx[6:0], miso_q};
              2'd3: rxb3[idx[9:2]] <= {sh_rx[6:0], miso_q};
            endcase
            idx <= idx + 10'd1;
            if ({1'b0, idx} == nbytes - 11'd1) begin
              busy <= 1'b0;
              if (!keep_cs) spi_cs_n <= 1'b1;
            end
          end
        end
      end
    end
  end
endmodule
`default_nettype wire
