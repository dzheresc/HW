// DDR control registers (BAR0 0xC00..0xFFC), single-word access, the DMA
// engine and the user-clock side of the DDR port. user_clk domain.
//
//   0xC00 DDR_STATUS RO  [0] calibration done  [1] MIG ui reset  [2] memtest busy
//                        [3] memtest done (since last start)  [4] DMA busy  [5] DMA done
//                        [6] DMA error  [7] bus master enable  [9:8] max payload code
//                        [14:12] max read request code  [16] single access busy
//   0xC04 DDR_INFO   RO  [15:0] size in MB (2048)  [23:16] DQ width (32)  [31:24] ui_clk MHz
//   0xC08 DDR_CTRL   RW  [0] MIG sys_rst (set, then clear, to recalibrate)
//   0xC10 MT_CTRL    RW  [1] write pass  [2] read/verify pass  [5:4] pattern mode;
//                        writing with [0] set starts the test
//   0xC14 MT_BASE    RW  byte address (32-byte aligned)
//   0xC18 MT_LEN     RW  bytes (multiple of 32, 0 = 4 GB is not allowed; max 2 GB)
//   0xC1C MT_SEED    RW
//   0xC20 MT_ERRS    RO  mismatched 32-bit words
//   0xC24 MT_WCYC    RO  write pass, ui_clk cycles
//   0xC28 MT_RCYC    RO  read pass, ui_clk cycles
//   0xC2C MT_ERRADDR RO  byte address of the first mismatch (0xFFFFFFFF: none)
//   0xC30 MT_ERREXP  RO  expected word there
//   0xC34 MT_ERRGOT  RO  read word there
//   0xC40 DMA_HOSTLO RW  host bus address (512-byte aligned)
//   0xC44 DMA_HOSTHI RW
//   0xC48 DMA_DDR    RW  DDR byte address (32-byte aligned)
//   0xC4C DMA_LEN    RW  bytes (multiple of 512)
//   0xC50 DMA_CTRL   W   [0] start  [1] direction (0 host->DDR, 1 DDR->host)
//   0xC54 DMA_STATUS RO  [0] busy [1] done [2] error [3] bus master enable
//                        [6:4] error code (1 no BME, 2 completion status, 3 timeout, 4 arguments)
//   0xC58 DMA_CYC    RO  user_clk (250 MHz) cycles of the last transfer
//   0xC5C DMA_DBG    RO
//   0xC80 SA_ADDR    RW  byte address (32-byte aligned) for single 32-byte accesses
//   0xC84 SA_CTRL    W   [0] read  [1] write (SA_DATA -> DDR);  R [0] busy
//   0xCA0..0xCBC SA_DATA RW  8 x 32 bits (word 0 = lowest address)
`default_nettype none
module ddr_ctrl #(
  parameter AW = 26,
  parameter [7:0] UI_MHZ = 8'd300
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
  // to the ui_clk domain
  output reg            mt_tog = 1'b0,
  output reg  [AW-1:0]  xcfg_mt_base = {AW{1'b0}},
  output reg  [AW:0]    xcfg_mt_len = {(AW+1){1'b0}},
  output reg            xcfg_mt_wr = 1'b1,
  output reg            xcfg_mt_rd = 1'b1,
  output reg  [1:0]     xcfg_mt_mode = 2'd0,
  output reg  [31:0]    xcfg_mt_seed = 32'd0,
  output reg            ddr_sys_rst = 1'b0,

  // PCIe config
  input  wire [1:0]     max_payload,
  input  wire [2:0]     max_read_req,
  input  wire           bme,
  // requester interfaces
  output wire [255:0]   rq_tdata,
  output wire [7:0]     rq_tkeep,
  output wire           rq_tlast,
  output wire [61:0]    rq_tuser,
  output wire           rq_tvalid,
  input  wire           rq_tready,
  input  wire [255:0]   rc_tdata,
  input  wire           rc_tlast,
  input  wire           rc_tvalid,
  output wire           rc_tready,

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
    if (rst) begin mt_pend <= 1'b0; mt_done <= 1'b0; end
  end
  assign mt_err_led = mt_done && mt_errs != 32'd0;

  // ---------------- DMA ----------------
  reg [63:0] dma_host = 64'd0;
  reg [31:0] dma_ddr = 32'd0, dma_len = 32'd0;
  wire dma_start = req && we && addr[11:2] == 10'h314 && wdata[0];
  wire dma_busy, dma_done;
  wire [2:0] dma_err;
  wire [31:0] dma_cyc, dma_dbg;

  wire          d_cv, d_cwe, d_rpop;
  wire [AW-1:0] d_ca;
  wire [255:0]  d_cd;
  ddr_dma #(.AW(AW)) dma (
    .clk(clk), .rst(rst | urst),
    .start(dma_start), .cfg_dir(wdata[1]), .cfg_host(dma_host), .cfg_ddr(dma_ddr), .cfg_len(dma_len),
    .max_payload(max_payload), .max_read_req(max_read_req), .bme(bme),
    .busy(dma_busy), .done(dma_done), .err(dma_err), .cycles(dma_cyc), .dbg(dma_dbg),
    .c_valid(d_cv), .c_ready(c_ready), .c_we(d_cwe), .c_addr(d_ca), .c_wdata(d_cd),
    .r_valid(r_valid), .r_data(r_data), .r_pop(d_rpop),
    .rq_tdata(rq_tdata), .rq_tkeep(rq_tkeep), .rq_tlast(rq_tlast), .rq_tuser(rq_tuser),
    .rq_tvalid(rq_tvalid), .rq_tready(rq_tready),
    .rc_tdata(rc_tdata), .rc_tlast(rc_tlast), .rc_tvalid(rc_tvalid), .rc_tready(rc_tready)
  );

  // ---------------- single access ----------------
  reg [31:0]  sa_addr = 32'd0;
  reg [255:0] sa_data = 256'd0;
  reg [1:0]   sa_st = 2'd0;    // 0 idle, 1 issue, 2 wait read data
  reg         sa_we = 1'b0;
  wire sa_issue = (sa_st == 2'd1);
  always @(posedge clk) begin
    if (req && we && addr[11:5] == 7'b1100101) sa_data[32 * addr[4:2] +: 32] <= wdata;  // 0xCA0..0xCBC
    case (sa_st)
      2'd0: if (req && we && addr[11:2] == 10'h321 && (wdata[1:0] != 2'b00) && !dma_busy) begin
        sa_we <= wdata[1];
        sa_st <= 2'd1;
      end
      2'd1: if (c_ready) sa_st <= sa_we ? 2'd0 : 2'd2;
      2'd2: if (r_valid) begin sa_data <= r_data; sa_st <= 2'd0; end
      default: sa_st <= 2'd0;
    endcase
    if (rst || urst) sa_st <= 2'd0;
  end

  // ---------------- DDR port mux (DMA while busy, else single access) ----------------
  assign c_valid = dma_busy ? d_cv    : sa_issue;
  assign c_we    = dma_busy ? d_cwe   : sa_we;
  assign c_addr  = dma_busy ? d_ca    : sa_addr[AW+4:5];
  assign c_wdata = dma_busy ? d_cd    : sa_data;
  assign r_pop   = dma_busy ? d_rpop  : (sa_st == 2'd2);

  // ---------------- register file ----------------
  always @(posedge clk) begin
    if (req && we) case (addr[11:2])
      10'h302: ddr_sys_rst <= wdata[0];
      10'h304: begin xcfg_mt_wr <= wdata[1]; xcfg_mt_rd <= wdata[2]; xcfg_mt_mode <= wdata[5:4]; end
      10'h305: xcfg_mt_base <= wdata[AW+4:5];
      10'h306: xcfg_mt_len <= wdata[AW+5:5];
      10'h307: xcfg_mt_seed <= wdata;
      10'h310: dma_host[31:0] <= wdata;
      10'h311: dma_host[63:32] <= wdata;
      10'h312: dma_ddr <= wdata;
      10'h313: dma_len <= wdata;
      10'h320: sa_addr <= wdata;
      default: ;
    endcase
    if (req) case (addr[11:2])
      10'h300: rdata <= {15'd0, sa_st != 2'd0, 1'b0, max_read_req, 2'b00, max_payload,
                         bme, dma_err != 3'd0, dma_done, dma_busy, mt_done, mtb | mt_pend, urst, cal};
      10'h301: rdata <= {UI_MHZ, 8'd32, 16'd2048};
      10'h302: rdata <= {31'd0, ddr_sys_rst};
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
      10'h310: rdata <= dma_host[31:0];
      10'h311: rdata <= dma_host[63:32];
      10'h312: rdata <= dma_ddr;
      10'h313: rdata <= dma_len;
      10'h315: rdata <= {25'd0, dma_err, bme, dma_err != 3'd0, dma_done, dma_busy};
      10'h316: rdata <= dma_cyc;
      10'h317: rdata <= dma_dbg;
      10'h320: rdata <= sa_addr;
      10'h321: rdata <= {31'd0, sa_st != 2'd0};
      default: rdata <= (addr[11:5] == 7'b1100101) ? sa_data[32 * addr[4:2] +: 32] : 32'd0;
    endcase
  end
endmodule
`default_nettype wire
