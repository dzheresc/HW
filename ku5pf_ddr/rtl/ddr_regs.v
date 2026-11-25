// Register file for the JTAG DDR4 demo (ctrl clock domain, 50 MHz board oscillator).
// Same DDR offsets as ku5p_ddr (ddr_ctrl.v), without the PCIe DMA:
//
//   0x000 ID         RO  "KUFD" (0x4B554644)
//   0x004 VERSION    RO
//   0x008 SCRATCH    RW
//   0x00C UPTIME     RO  ctrl clock cycles (free running)
//   0x010 UI_FREQ    RO  ui_clk cycles per 1 ms of the ctrl clock (300 at 2400 MT/s -> 300000)
//   0xC00 DDR_STATUS RO  [0] calibration done  [1] MIG ui reset  [2] memtest busy
//                        [3] memtest done (since last start)  [16] single access busy
//   0xC04 DDR_INFO   RO  [15:0] size in MB (2048)  [23:16] DQ width (32)
//   0xC08 DDR_CTRL   RW  [0] MIG sys_rst (set, then clear, to recalibrate)
//   0xC0C DDR_UIMHZ  RO  ui_clk MHz (build parameter)
//   0xC10 MT_CTRL    RW  [1] write pass  [2] read/verify pass  [5:4] pattern mode;
//                        writing with [0] set starts the test
//   0xC14 MT_BASE    RW  byte address (32-byte aligned)
//   0xC18 MT_LEN     RW  bytes (multiple of 32, max 2 GB)
//   0xC1C MT_SEED    RW
//   0xC20 MT_ERRS    RO  mismatched 32-bit words
//   0xC24 MT_WCYC    RO  write pass, ui_clk cycles
//   0xC28 MT_RCYC    RO  read pass, ui_clk cycles
//   0xC2C MT_ERRADDR RO  byte address of the first mismatch (0xFFFFFFFF: none)
//   0xC30 MT_ERREXP  RO  expected word there
//   0xC34 MT_ERRGOT  RO  read word there
//   0xC80 SA_ADDR    RW  byte address (32-byte aligned) for single 32-byte accesses
//   0xC84 SA_CTRL    W   [0] read  [1] write (SA_DATA -> DDR);  R [0] busy
//   0xCA0..0xCBC SA_DATA RW  8 x 32 bits (word 0 = lowest address = first beat of the BL8)
`default_nettype none
module ddr_regs #(
  parameter AW = 26,
  parameter [15:0] UI_MHZ = 16'd300,
  parameter [31:0] VERSION = 32'h0001_0000,
  parameter integer CLK_HZ = 50_000_000
) (
  input  wire           clk,
  input  wire           rst,
  input  wire           req,
  input  wire           we,
  input  wire [11:2]    addr,
  input  wire [31:0]    wdata,
  output reg  [31:0]    rdata,

  // status from the ui_clk domain (raw, synchronized here)
  input  wire           calib_raw,
  input  wire           ui_rst_raw,
  input  wire           mt_busy_raw,
  input  wire [31:0]    mt_errs, mt_wcyc, mt_rcyc, mt_err_addr, mt_err_exp, mt_err_got,
  input  wire [31:0]    xst_ui_freq,   // from the ui_clk domain, quasi-static
  output reg            ms_tog = 1'b0, // toggles every 1 ms (ui_clk frequency meter)
  // to the ui_clk domain
  output reg            mt_tog = 1'b0,
  output reg  [AW-1:0]  xcfg_mt_base = {AW{1'b0}},
  output reg  [AW:0]    xcfg_mt_len = {(AW+1){1'b0}},
  output reg            xcfg_mt_wr = 1'b1,
  output reg            xcfg_mt_rd = 1'b1,
  output reg  [1:0]     xcfg_mt_mode = 2'd0,
  output reg  [31:0]    xcfg_mt_seed = 32'd0,
  output reg            ddr_sys_rst = 1'b0,

  // DDR port (ddr_bridge user side)
  output wire           c_valid,
  input  wire           c_ready,
  output wire           c_we,
  output wire [AW-1:0]  c_addr,
  output wire [255:0]   c_wdata,
  input  wire           r_valid,
  input  wire [255:0]   r_data,
  output wire           r_pop,

  output wire           calib_done,
  output wire           mt_done_o,
  output wire           mt_err_led
);
  // ---------------- synchronizers ----------------
  (* ASYNC_REG = "TRUE" *) reg [2:0] xs0_cal = 3'd0, xs0_urst = 3'd7, xs0_mtb = 3'd0;
  always @(posedge clk) begin
    xs0_cal  <= {xs0_cal[1:0], calib_raw};
    xs0_urst <= {xs0_urst[1:0], ui_rst_raw};
    xs0_mtb  <= {xs0_mtb[1:0], mt_busy_raw};
  end
  wire cal = xs0_cal[2], urst = xs0_urst[2], mtb = xs0_mtb[2];
  assign calib_done = cal;

  // ---------------- uptime, 1 ms tick ----------------
  reg [31:0] uptime = 32'd0;
  reg [31:0] ms_cnt = 32'd0;
  always @(posedge clk) begin
    uptime <= uptime + 32'd1;
    if (ms_cnt == CLK_HZ / 1000 - 1) begin ms_cnt <= 32'd0; ms_tog <= ~ms_tog; end
    else ms_cnt <= ms_cnt + 32'd1;
  end

  // memtest done: busy seen, then dropped. A start waits for the busy edge.
  reg mt_pend = 1'b0, mt_seen = 1'b0, mt_done = 1'b0;
  always @(posedge clk) begin
    if (mt_pend && mtb) begin mt_seen <= 1'b1; end
    if (mt_pend && mt_seen && !mtb) begin mt_pend <= 1'b0; mt_seen <= 1'b0; mt_done <= 1'b1; end
    if (req && we && addr[11:2] == 10'h304 && wdata[0] && !mt_pend) begin
      mt_tog <= ~mt_tog;
      mt_pend <= 1'b1;
      mt_seen <= 1'b0;
      mt_done <= 1'b0;
    end
    if (rst || urst) begin mt_pend <= 1'b0; mt_seen <= 1'b0; end
    if (rst) mt_done <= 1'b0;
  end
  assign mt_done_o  = mt_done;
  assign mt_err_led = mt_done && mt_errs != 32'd0;

  // ---------------- single access ----------------
  reg [31:0]  sa_addr = 32'd0;
  reg [255:0] sa_data = 256'd0;
  reg [1:0]   sa_st = 2'd0;    // 0 idle, 1 issue, 2 wait read data
  reg         sa_we = 1'b0;
  wire sa_issue = (sa_st == 2'd1);
  always @(posedge clk) begin
    if (req && we && addr[11:5] == 7'b1100101) sa_data[32 * addr[4:2] +: 32] <= wdata;  // 0xCA0..0xCBC
    case (sa_st)
      2'd0: if (req && we && addr[11:2] == 10'h321 && (wdata[1:0] != 2'b00) && cal && !mt_pend) begin
        sa_we <= wdata[1];
        sa_st <= 2'd1;
      end
      2'd1: if (c_ready) sa_st <= sa_we ? 2'd0 : 2'd2;
      2'd2: if (r_valid) begin sa_data <= r_data; sa_st <= 2'd0; end
      default: sa_st <= 2'd0;
    endcase
    if (rst || urst) sa_st <= 2'd0;
  end

  assign c_valid = sa_issue;
  assign c_we    = sa_we;
  assign c_addr  = sa_addr[AW+4:5];
  assign c_wdata = sa_data;
  assign r_pop   = (sa_st == 2'd2);

  // ---------------- register file ----------------
  reg [31:0] scratch = 32'd0;
  always @(posedge clk) begin
    if (req && we) case (addr[11:2])
      10'h002: scratch <= wdata;
      10'h302: ddr_sys_rst <= wdata[0];
      10'h304: begin xcfg_mt_wr <= wdata[1]; xcfg_mt_rd <= wdata[2]; xcfg_mt_mode <= wdata[5:4]; end
      10'h305: xcfg_mt_base <= wdata[AW+4:5];
      10'h306: xcfg_mt_len <= wdata[AW+5:5];
      10'h307: xcfg_mt_seed <= wdata;
      10'h320: sa_addr <= wdata;
      default: ;
    endcase
    if (req) case (addr[11:2])
      10'h000: rdata <= 32'h4B55_4644;
      10'h001: rdata <= VERSION;
      10'h002: rdata <= scratch;
      10'h003: rdata <= uptime;
      10'h004: rdata <= xst_ui_freq;
      10'h300: rdata <= {15'd0, sa_st != 2'd0, 12'd0, mt_done, mtb | mt_pend, urst, cal};
      10'h301: rdata <= {8'd0, 8'd32, 16'd2048};
      10'h302: rdata <= {31'd0, ddr_sys_rst};
      10'h303: rdata <= {16'd0, UI_MHZ};
      10'h304: rdata <= {26'd0, xcfg_mt_mode, 1'b0, xcfg_mt_rd, xcfg_mt_wr, 1'b0};
      10'h305: rdata <= {xcfg_mt_base, 5'd0};
      10'h306: rdata <= {xcfg_mt_len, 5'd0};
      10'h307: rdata <= xcfg_mt_seed;
      10'h308: rdata <= mt_errs;
      10'h309: rdata <= mt_wcyc;
      10'h30A: rdata <= mt_rcyc;
      10'h30B: rdata <= mt_err_addr;
      10'h30C: rdata <= mt_err_exp;
      10'h30D: rdata <= mt_err_got;
      10'h320: rdata <= sa_addr;
      10'h321: rdata <= {31'd0, sa_st != 2'd0};
      default: rdata <= (addr[11:5] == 7'b1100101) ? sa_data[32 * addr[4:2] +: 32] : 32'd0;
    endcase
  end
endmodule
`default_nettype wire
