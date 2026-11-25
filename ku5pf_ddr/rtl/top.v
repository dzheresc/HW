// RK-XCKU5P-F ("fat" KU5P board): DDR4 read/write demo driven over JTAG only.
//   - MIG DDR4, native interface: 2 x MT40A512M16LY-062E (x16) = 32-bit, 2 GB
//   - JTAG-to-AXI master (AXI4-Lite) on the 50 MHz board oscillator -> ddr_regs
//   - single 32-byte accesses (one BL8 burst) and the in-fabric memory test (ddr_memtest)
// The register side runs on the board oscillator, independent of the MIG, so JTAG access
// (and MIG reset / recalibration) keeps working whether or not the DDR calibrates.
`default_nettype none
module top #(
  parameter [15:0] UI_MHZ = 16'd300
) (
  input  wire              clk50,

  input  wire              c0_sys_clk_p,
  input  wire              c0_sys_clk_n,
  output wire              c0_ddr4_act_n,
  output wire [16:0]       c0_ddr4_adr,
  output wire [1:0]        c0_ddr4_ba,
  output wire [0:0]        c0_ddr4_bg,
  output wire [0:0]        c0_ddr4_cke,
  output wire [0:0]        c0_ddr4_odt,
  output wire [0:0]        c0_ddr4_cs_n,
  output wire [0:0]        c0_ddr4_ck_t,
  output wire [0:0]        c0_ddr4_ck_c,
  output wire              c0_ddr4_reset_n,
  inout  wire [3:0]        c0_ddr4_dm_dbi_n,
  inout  wire [31:0]       c0_ddr4_dq,
  inout  wire [3:0]        c0_ddr4_dqs_t,
  inout  wire [3:0]        c0_ddr4_dqs_c,

  output wire [3:0]        led
);
  localparam AW = 26;

  // ---------------- control clock ----------------
  // STARTUPE3 CFGMCLK (internal ~50 MHz config oscillator, +-15%): always running, so the
  // debug hub / JTAG-AXI never depend on a board oscillator or on the MIG.
  wire cfgmclk, clk;
  STARTUPE3 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) startup (
    .CFGCLK(), .CFGMCLK(cfgmclk), .EOS(), .PREQ(), .DI(),
    .DO(4'b1111), .DTS(4'b1111), .FCSBO(1'b1), .FCSBTS(1'b1),
    .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
    .USRCCLKO(1'b0), .USRCCLKTS(1'b1), .USRDONEO(1'b1), .USRDONETS(1'b1)
  );
  BUFG clk_bufg (.I(cfgmclk), .O(clk));
  // board 50 MHz oscillator (PL_CLK): only a heartbeat LED, to show whether it runs
  wire pl_clk;
  BUFG pl_bufg (.I(clk50), .O(pl_clk));
  reg [7:0] por_cnt = 8'd0;
  wire por = ~por_cnt[7];
  always @(posedge clk) if (por) por_cnt <= por_cnt + 8'd1;

  // ---------------- JTAG-to-AXI master (AXI4-Lite) ----------------
  wire [31:0] awaddr, wdata_a, araddr;  wire awvalid, wvalid, arvalid, bready, rready;
  wire [3:0] wstrb;
  reg  awready = 1'b0, wready = 1'b0, bvalid = 1'b0, arready = 1'b0, rvalid = 1'b0;
  reg  [31:0] rdata_a = 32'd0;

  jtag_axi_m jtag_axi (
    .aclk(clk), .aresetn(~por),
    .m_axi_awaddr(awaddr), .m_axi_awprot(), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata_a), .m_axi_wstrb(wstrb), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(2'b00), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_araddr(araddr), .m_axi_arprot(), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rdata(rdata_a), .m_axi_rresp(2'b00), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  // AXI-Lite slave -> one-cycle register bus (reads answer one cycle after req)
  localparam A_IDLE = 2'd0, A_WR = 2'd1, A_RD = 2'd2, A_RD2 = 2'd3;
  reg [1:0]  ast = A_IDLE;
  reg        r_req = 1'b0, r_we = 1'b0;
  reg [11:2] r_addr = 10'd0;
  reg [31:0] r_wdata = 32'd0;
  wire [31:0] bus_rdata;
  always @(posedge clk) begin
    awready <= 1'b0;  wready <= 1'b0;  arready <= 1'b0;  r_req <= 1'b0;
    if (bvalid && bready) bvalid <= 1'b0;
    if (rvalid && rready) rvalid <= 1'b0;
    if (por) begin
      ast <= A_IDLE;  bvalid <= 1'b0;  rvalid <= 1'b0;
    end else case (ast)
      A_IDLE: if (!bvalid && !rvalid && !awready && !arready) begin
        if (awvalid && wvalid) begin
          awready <= 1'b1;  wready <= 1'b1;
          r_req <= 1'b1;  r_we <= 1'b1;  r_addr <= awaddr[11:2];  r_wdata <= wdata_a;
          ast <= A_WR;
        end else if (arvalid) begin
          arready <= 1'b1;
          r_req <= 1'b1;  r_we <= 1'b0;  r_addr <= araddr[11:2];
          ast <= A_RD;
        end
      end
      A_WR:  begin bvalid <= 1'b1; ast <= A_IDLE; end
      A_RD:  ast <= A_RD2;                              // rdata registered on req
      A_RD2: begin rvalid <= 1'b1; rdata_a <= bus_rdata; ast <= A_IDLE; end
      default: ast <= A_IDLE;
    endcase
  end

  // ---------------- DDR4 ----------------
  wire          ui_clk, ui_rst, calib;
  wire          app_en, app_wdf_wren, app_wdf_end, app_rdy, app_wdf_rdy, app_rd_valid;
  wire [2:0]    app_cmd;
  wire [28:0]   app_addr;
  wire [255:0]  app_wdf_data, app_rd_data;
  wire [31:0]   app_wdf_mask;
  wire          ddr_sys_rst;

  // MIG reset: power-on (ctrl clock) or the DDR_CTRL register
  ddr4_0 mig (
    .c0_sys_clk_p(c0_sys_clk_p), .c0_sys_clk_n(c0_sys_clk_n), .sys_rst(ddr_sys_rst | por),
    .c0_init_calib_complete(calib), .dbg_clk(), .dbg_bus(),
    .c0_ddr4_adr(c0_ddr4_adr), .c0_ddr4_ba(c0_ddr4_ba), .c0_ddr4_cke(c0_ddr4_cke),
    .c0_ddr4_cs_n(c0_ddr4_cs_n), .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n), .c0_ddr4_dq(c0_ddr4_dq),
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c), .c0_ddr4_dqs_t(c0_ddr4_dqs_t), .c0_ddr4_odt(c0_ddr4_odt),
    .c0_ddr4_bg(c0_ddr4_bg), .c0_ddr4_reset_n(c0_ddr4_reset_n), .c0_ddr4_act_n(c0_ddr4_act_n),
    .c0_ddr4_ck_c(c0_ddr4_ck_c), .c0_ddr4_ck_t(c0_ddr4_ck_t),
    .c0_ddr4_ui_clk(ui_clk), .c0_ddr4_ui_clk_sync_rst(ui_rst),
    .c0_ddr4_app_en(app_en), .c0_ddr4_app_hi_pri(1'b0), .c0_ddr4_app_wdf_end(app_wdf_end),
    .c0_ddr4_app_wdf_wren(app_wdf_wren), .c0_ddr4_app_rd_data_end(),
    .c0_ddr4_app_rd_data_valid(app_rd_valid), .c0_ddr4_app_rdy(app_rdy),
    .c0_ddr4_app_wdf_rdy(app_wdf_rdy), .c0_ddr4_app_addr(app_addr), .c0_ddr4_app_cmd(app_cmd),
    .c0_ddr4_app_wdf_data(app_wdf_data), .c0_ddr4_app_wdf_mask(app_wdf_mask),
    .c0_ddr4_app_rd_data(app_rd_data)
  );

  // ctrl-clock side reset of the DDR port: POR or MIG in reset
  (* ASYNC_REG = "TRUE" *) reg [2:0] xs0_uir = 3'b111;
  always @(posedge clk) xs0_uir <= {xs0_uir[1:0], ui_rst};
  wire ddr_urst = por | xs0_uir[2];

  wire          c_valid, c_ready, c_we, r_valid, r_pop;
  wire [AW-1:0] c_addr;
  wire [255:0]  c_wdata, r_data;
  wire          mt_tog, ms_tog;
  wire [AW-1:0] mt_base;  wire [AW:0] mt_len;  wire mt_wr, mt_rd;  wire [1:0] mt_mode;
  wire [31:0]   mt_seed;
  wire          mt_busy;
  wire [31:0]   mt_errs, mt_wcyc, mt_rcyc, mt_err_addr, mt_err_exp, mt_err_got;
  wire          calib_done, mt_done, mt_err_led;
  reg  [31:0]   xst_ui_freq = 32'd0;

  ddr_regs #(.AW(AW), .UI_MHZ(UI_MHZ)) regs (
    .clk(clk), .rst(por),
    .req(r_req), .we(r_we), .addr(r_addr), .wdata(r_wdata), .rdata(bus_rdata),
    .calib_raw(calib), .ui_rst_raw(ui_rst), .mt_busy_raw(mt_busy),
    .mt_errs(mt_errs), .mt_wcyc(mt_wcyc), .mt_rcyc(mt_rcyc),
    .mt_err_addr(mt_err_addr), .mt_err_exp(mt_err_exp), .mt_err_got(mt_err_got),
    .xst_ui_freq(xst_ui_freq), .ms_tog(ms_tog),
    .mt_tog(mt_tog), .xcfg_mt_base(mt_base), .xcfg_mt_len(mt_len), .xcfg_mt_wr(mt_wr),
    .xcfg_mt_rd(mt_rd), .xcfg_mt_mode(mt_mode), .xcfg_mt_seed(mt_seed), .ddr_sys_rst(ddr_sys_rst),
    .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata),
    .r_valid(r_valid), .r_data(r_data), .r_pop(r_pop),
    .calib_done(calib_done), .mt_done_o(mt_done), .mt_err_led(mt_err_led)
  );

  // toggles from the ctrl clock into ui_clk: memtest start, 1 ms tick
  (* ASYNC_REG = "TRUE" *) reg [2:0] xs0_mtt = 3'b000, xs0_ms = 3'b000;
  reg mtt_q = 1'b0, ms_q = 1'b0;
  reg [31:0] ui_cnt = 32'd0;
  always @(posedge ui_clk) begin
    xs0_mtt <= {xs0_mtt[1:0], mt_tog};
    mtt_q <= xs0_mtt[2];
    xs0_ms <= {xs0_ms[1:0], ms_tog};
    ms_q <= xs0_ms[2];
    if (xs0_ms[2] ^ ms_q) begin xst_ui_freq <= ui_cnt; ui_cnt <= 32'd1; end
    else ui_cnt <= ui_cnt + 32'd1;
  end
  wire mt_start = xs0_mtt[2] ^ mtt_q;

  wire          br_idle, mt_sel, mt_en, mt_wren;
  wire [2:0]    mt_cmd;
  wire [28:0]   mt_addr;
  wire [255:0]  mt_wdata;

  ddr_memtest #(.AW(AW)) memtest (
    .clk(ui_clk), .rst(ui_rst), .start(mt_start),
    .cfg_base(mt_base), .cfg_len(mt_len), .cfg_wr(mt_wr), .cfg_rd(mt_rd), .cfg_mode(mt_mode),
    .cfg_seed(mt_seed), .br_idle(br_idle),
    .sel(mt_sel), .app_en(mt_en), .app_cmd(mt_cmd), .app_addr(mt_addr), .app_wren(mt_wren),
    .app_wdata(mt_wdata), .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy),
    .rd_valid(app_rd_valid), .rd_data(app_rd_data),
    .busy(mt_busy), .xst_errs(mt_errs), .xst_wcyc(mt_wcyc), .xst_rcyc(mt_rcyc),
    .xst_err_addr(mt_err_addr), .xst_err_exp(mt_err_exp), .xst_err_got(mt_err_got)
  );

  ddr_bridge #(.AW(AW)) bridge (
    .uclk(clk), .urst(ddr_urst),
    .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata),
    .r_valid(r_valid), .r_data(r_data), .r_pop(r_pop),
    .ui_clk(ui_clk), .ui_rst(ui_rst), .br_idle(br_idle),
    .mt_sel(mt_sel), .mt_en(mt_en), .mt_cmd(mt_cmd), .mt_addr(mt_addr), .mt_wren(mt_wren),
    .mt_wdata(mt_wdata),
    .app_en(app_en), .app_cmd(app_cmd), .app_addr(app_addr), .app_wdf_wren(app_wdf_wren),
    .app_wdf_end(app_wdf_end), .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask),
    .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy), .app_rd_data_valid(app_rd_valid),
    .app_rd_data(app_rd_data)
  );

  // ---------------- LEDs ----------------
  // LED1 PL_CLK heartbeat (~0.75 Hz), LED2 ui_clk heartbeat (~1.1 Hz, MIG PLL running),
  // LED3 calibration done, LED4 memory test found errors
  reg [25:0] hb = 26'd0;
  reg [27:0] hb_ui = 28'd0;
  always @(posedge pl_clk) hb <= hb + 26'd1;
  always @(posedge ui_clk) hb_ui <= hb_ui + 28'd1;
  assign led = {mt_err_led, calib_done, hb_ui[27], hb[25]};
endmodule
`default_nettype wire
