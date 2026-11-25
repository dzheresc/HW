// KU5P board DDR4 demo: the ku5p_pcie endpoint (pcie4_uscale_plus, 256-bit @ 250 MHz,
// 10ee:9021, BAR0 4 KB, config-flash SPI master + REBOOT register, JTAG-to-AXI)
// plus the board's 2 GB DDR4 (MIG, native interface, 32-bit, 2400 MT/s):
//   - ddr_memtest: in-fabric write/verify at full controller rate (ui_clk)
//   - ddr_dma:     host memory <-> DDR over the PCIe requester interfaces
//   - single 32-byte accesses from registers
// Registers: 0x000..0xBFC as ku5p_pcie (spi_regs.v), 0xC00..0xFFC DDR (ddr_ctrl.v).
// FEAT: [1] reboot register, [2] DDR block.
`default_nettype none
module top #(
  parameter LANES  = 8,
  parameter DATA_W = 256,       // must match axisten_if_width in gen_ip.tcl
  parameter [15:0] UI_MHZ = 16'd300
) (
  input  wire              pcie_perst_n,
  input  wire              pcie_refclk_p,
  input  wire              pcie_refclk_n,
  input  wire [LANES-1:0]  pci_exp_rxp,
  input  wire [LANES-1:0]  pci_exp_rxn,
  output wire [LANES-1:0]  pci_exp_txp,
  output wire [LANES-1:0]  pci_exp_txn,

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

  output wire [5:0]        led
);
  localparam NDW = DATA_W / 32;
  localparam AW  = 26;
  localparam [31:0] FEAT = 32'h6;   // [1] reboot, [2] DDR

  // ---------------- clocks / resets ----------------
  wire refclk_gt, refclk_div2;
  IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) refclk_ibuf (
    .O(refclk_gt), .ODIV2(refclk_div2), .CEB(1'b0), .I(pcie_refclk_p), .IB(pcie_refclk_n));
  wire perst_n;
  IBUF perst_ibuf (.I(pcie_perst_n), .O(perst_n));

  wire user_clk, user_reset, user_lnk_up;

  reg [7:0] por_cnt = 8'd0;
  wire por = ~por_cnt[7];
  always @(posedge user_clk) if (por) por_cnt <= por_cnt + 8'd1;

  // ---------------- PCIe core ----------------
  wire [DATA_W-1:0] cq_tdata;  wire [NDW-1:0] cq_tkeep;  wire cq_tlast, cq_tvalid, cq_tready;
  wire [87:0]       cq_tuser;
  wire [DATA_W-1:0] cc_tdata;  wire [NDW-1:0] cc_tkeep;  wire cc_tlast, cc_tvalid;  wire [3:0] cc_tready;
  wire [255:0] rq_tdata;  wire [7:0] rq_tkeep;  wire rq_tlast, rq_tvalid;  wire [61:0] rq_tuser;
  wire [3:0]   rq_tready;
  wire [255:0] rc_tdata;  wire rc_tlast, rc_tvalid, rc_tready;
  wire [5:0] ltssm;  wire [1:0] cur_speed;  wire [2:0] neg_width;
  wire       pwr_chg;
  wire       phy_rdy;
  wire [1:0] max_payload;  wire [2:0] max_read_req;  wire [15:0] func_status;

  pcie_ku pcie (
    .pci_exp_txp(pci_exp_txp), .pci_exp_txn(pci_exp_txn),
    .pci_exp_rxp(pci_exp_rxp), .pci_exp_rxn(pci_exp_rxn),
    .user_clk(user_clk), .user_reset(user_reset), .user_lnk_up(user_lnk_up),

    .s_axis_rq_tdata(rq_tdata), .s_axis_rq_tkeep(rq_tkeep), .s_axis_rq_tlast(rq_tlast),
    .s_axis_rq_tuser(rq_tuser), .s_axis_rq_tvalid(rq_tvalid), .s_axis_rq_tready(rq_tready),
    .m_axis_rc_tdata(rc_tdata), .m_axis_rc_tkeep(), .m_axis_rc_tlast(rc_tlast), .m_axis_rc_tuser(),
    .m_axis_rc_tvalid(rc_tvalid), .m_axis_rc_tready(rc_tready),

    .m_axis_cq_tdata(cq_tdata), .m_axis_cq_tkeep(cq_tkeep), .m_axis_cq_tlast(cq_tlast),
    .m_axis_cq_tuser(cq_tuser), .m_axis_cq_tvalid(cq_tvalid), .m_axis_cq_tready(cq_tready),
    .s_axis_cc_tdata(cc_tdata), .s_axis_cc_tkeep(cc_tkeep), .s_axis_cc_tlast(cc_tlast),
    .s_axis_cc_tuser(33'd0), .s_axis_cc_tvalid(cc_tvalid), .s_axis_cc_tready(cc_tready),

    .pcie_cq_np_req(2'b11),
    .pcie_cq_np_req_count(),

    .cfg_ltssm_state(ltssm), .cfg_current_speed(cur_speed), .cfg_negotiated_width(neg_width),
    .cfg_max_payload(max_payload), .cfg_max_read_req(max_read_req), .cfg_function_status(func_status),
    .cfg_dsn(64'h0000_0002_0000_0EE1),
    .cfg_link_training_enable(1'b1),
    .cfg_config_space_enable(1'b1),
    .cfg_power_state_change_interrupt(pwr_chg), .cfg_power_state_change_ack(pwr_chg),
    .cfg_err_cor_in(1'b0), .cfg_err_uncor_in(1'b0), .cfg_flr_done(4'd0),
    .cfg_interrupt_int(4'd0), .cfg_interrupt_pending(4'd0), .cfg_interrupt_sent(),
    .cfg_hot_reset_in(1'b0), .cfg_req_pm_transition_l23_ready(1'b0),

    .sys_clk(refclk_div2), .sys_clk_gt(refclk_gt), .sys_reset(perst_n),
    .phy_rdy_out(phy_rdy)
  );

  // ---------------- PCIe target ----------------
  wire [2:0] pio_state;  wire [31:0] pio_dw0, pio_dw2;
  wire p_req;
  reg [7:0] cq_cnt = 8'd0, cc_cnt = 8'd0, pb_cnt = 8'd0;
  always @(posedge user_clk) begin
    if (cq_tvalid && cq_tready) cq_cnt <= cq_cnt + 8'd1;
    if (cc_tvalid && cc_tready[0]) cc_cnt <= cc_cnt + 8'd1;
    if (p_req) pb_cnt <= pb_cnt + 8'd1;
  end
  wire [31:0] dbg0;
  wire p_we;  wire [11:2] p_addr;  wire [31:0] p_wdata;
  assign dbg0 = {cq_cnt, cc_cnt, pb_cnt, cq_tvalid, cq_tready, cc_tvalid, cc_tready[0], 1'b0, pio_state};
  wire        bus_ack;  wire [31:0] bus_rdata;
  reg         ack_to_pcie;

  pcie_cq_pio #(.DATA_W(DATA_W)) pio (
    .clk(user_clk), .rst(user_reset),
    .cq_tdata(cq_tdata), .cq_tlast(cq_tlast), .cq_tvalid(cq_tvalid), .cq_tready(cq_tready),
    .cq_tuser(cq_tuser),
    .cc_tdata(cc_tdata), .cc_tkeep(cc_tkeep), .cc_tlast(cc_tlast), .cc_tvalid(cc_tvalid),
    .cc_tready(cc_tready[0]),
    .bus_req(p_req), .bus_we(p_we), .bus_addr(p_addr), .bus_wdata(p_wdata),
    .bus_ack(bus_ack & ack_to_pcie), .bus_rdata(bus_rdata),
    .dbg_state(pio_state), .dbg_dw0(pio_dw0), .dbg_dw2(pio_dw2)
  );

  // ---------------- JTAG-to-AXI master (AXI4-Lite) ----------------
  wire [31:0] awaddr, wdata_a, araddr;  wire awvalid, wvalid, arvalid, bready, rready;
  wire [3:0] wstrb;
  reg  awready = 1'b0, wready = 1'b0, bvalid = 1'b0, arready = 1'b0, rvalid = 1'b0;
  reg  [31:0] rdata_a;

  jtag_axi_m jtag_axi (
    .aclk(user_clk), .aresetn(~por),
    .m_axi_awaddr(awaddr), .m_axi_awprot(), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata_a), .m_axi_wstrb(wstrb), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(2'b00), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_araddr(araddr), .m_axi_arprot(), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rdata(rdata_a), .m_axi_rresp(2'b00), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );

  // AXI-Lite to register bus (same as k7_pcie). PCIe has priority.
  localparam A_IDLE = 2'd0, A_WAIT_W = 2'd1, A_WAIT_R = 2'd2;
  reg [1:0]  ast = A_IDLE;
  reg        a_pend = 1'b0, a_we = 1'b0;
  reg [31:0] a_addr_q, a_wdata_q;
  wire       a_go = a_pend & ~p_req;
  reg        ack_to_axi = 1'b0;
  always @(posedge user_clk) begin
    awready <= 1'b0;  wready <= 1'b0;  arready <= 1'b0;
    ack_to_axi <= a_go;
    if (a_go) a_pend <= 1'b0;
    if (bvalid && bready) bvalid <= 1'b0;
    if (rvalid && rready) rvalid <= 1'b0;
    if (por) begin
      ast <= A_IDLE;  bvalid <= 1'b0;  rvalid <= 1'b0;  a_pend <= 1'b0;
    end else case (ast)
      A_IDLE: if (!bvalid && !rvalid && !awready && !arready) begin
        if (awvalid && wvalid) begin
          awready <= 1'b1;  wready <= 1'b1;
          a_addr_q <= awaddr;  a_wdata_q <= wdata_a;
          a_pend <= 1'b1;  a_we <= 1'b1;  ast <= A_WAIT_W;
        end else if (arvalid) begin
          arready <= 1'b1;
          a_addr_q <= araddr;
          a_pend <= 1'b1;  a_we <= 1'b0;  ast <= A_WAIT_R;
        end
      end
      A_WAIT_W: if (ack_to_axi) begin bvalid <= 1'b1; ast <= A_IDLE; end
      A_WAIT_R: if (ack_to_axi) begin rvalid <= 1'b1; rdata_a <= bus_rdata; ast <= A_IDLE; end
      default: ast <= A_IDLE;
    endcase
  end

  wire        r_req   = p_req | a_go;
  wire        r_we    = p_req ? p_we : a_we;
  wire [11:2] r_addr  = p_req ? p_addr : a_addr_q[11:2];
  wire [31:0] r_wdata = p_req ? p_wdata : a_wdata_q;
  always @(posedge user_clk) ack_to_pcie <= p_req;

  // register read mux: both blocks answer one cycle after req
  reg         r_ddr_q = 1'b0;
  always @(posedge user_clk) if (r_req) r_ddr_q <= (r_addr[11:10] == 2'b11);
  wire [31:0] spi_rdata, ddr_rdata;
  assign bus_rdata = r_ddr_q ? ddr_rdata : spi_rdata;

  // ---------------- SPI registers ----------------
  wire spi_sck, spi_cs_n, spi_mosi, spi_miso, spi_busy, spi_sel;
  wire reboot_go, cfgmclk;
  reg [1:0] perst_s = 2'b00, phy_s = 2'b00;
  reg [5:0] ltssm_max = 6'd0;
  always @(posedge user_clk) begin
    perst_s <= {perst_s[0], perst_n};
    phy_s   <= {phy_s[0], phy_rdy};
    if (ltssm > ltssm_max) ltssm_max <= ltssm;
  end
  wire [31:0] link_status = {2'b00, ltssm_max, 5'd0, user_reset, perst_s[1], phy_s[1],
                             user_lnk_up, neg_width, 2'b00, cur_speed, 2'b00, ltssm};

  spi_regs #(.ID(32'h4B555043), .VERSION(32'h00030000), .FEAT(FEAT), .HALF_RESET(8'd8)) regs (
    .clk(user_clk), .rst(por),
    .req(r_req), .we(r_we), .addr(r_addr), .wdata(r_wdata), .ack(bus_ack), .rdata(spi_rdata),
    .link_status(link_status),
    .dbg0(dbg0), .dbg1(pio_dw0), .dbg2(pio_dw2),
    .spi_sck(spi_sck), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
    .spi_sel(spi_sel), .busy_o(spi_busy), .reboot_go(reboot_go)
  );

  // ---------------- primary flash via STARTUPE3 ----------------
  reg  cs0_q = 1'b1, mosi_q = 1'b1;
  wire [3:0] sdi;
  always @(posedge user_clk) begin
    cs0_q  <= spi_cs_n | spi_sel;
    mosi_q <= spi_mosi;
  end

  STARTUPE3 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) startup (
    .CFGCLK(), .CFGMCLK(cfgmclk), .EOS(), .PREQ(),
    .DI(sdi),
    .DO({2'b11, 1'b1, mosi_q}),
    .DTS(4'b0010),
    .FCSBO(cs0_q), .FCSBTS(1'b0),
    .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
    .USRCCLKO(spi_sck), .USRCCLKTS(1'b0),
    .USRDONEO(1'b1), .USRDONETS(1'b1)
  );

  wire icap_clk;
  BUFG cfgmclk_bufg (.I(cfgmclk), .O(icap_clk));
  fpga_reboot #(.FAMILY("USP")) reboot (.clk(user_clk), .go(reboot_go), .icap_clk(icap_clk), .busy());
  wire [15:0] die_temp;
  temp_mon tmon (.dclk(icap_clk), .xst_temp(die_temp));

  reg miso0_q;
  always @(posedge user_clk) miso0_q <= sdi[1];
  assign spi_miso = miso0_q;

  // ---------------- DDR4 ----------------
  wire          ui_clk, ui_rst, calib;
  wire          app_en, app_wdf_wren, app_wdf_end, app_rdy, app_wdf_rdy, app_rd_valid;
  wire [2:0]    app_cmd;
  wire [28:0]   app_addr;
  wire [255:0]  app_wdf_data, app_rd_data;
  wire [31:0]   app_wdf_mask;
  wire          ddr_sys_rst;
  wire          mig_dbg_clk;   // debug hub clock when the MIG debug is enabled (debug.xdc)

  ddr4_0 mig (
    .c0_sys_clk_p(c0_sys_clk_p), .c0_sys_clk_n(c0_sys_clk_n), .sys_rst(ddr_sys_rst),
    .c0_init_calib_complete(calib), .dbg_clk(mig_dbg_clk), .dbg_bus(),
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

  // user-clock side reset of the DDR port: POR or MIG in reset
  (* ASYNC_REG = "TRUE" *) reg [2:0] xs0_uir = 3'b111;
  always @(posedge user_clk) xs0_uir <= {xs0_uir[1:0], ui_rst};
  wire ddr_urst = por | xs0_uir[2];

  wire          c_valid, c_ready, c_we, r_valid, r_pop;
  wire [AW-1:0] c_addr;
  wire [255:0]  c_wdata, r_data;
  wire          mt_tog;
  wire [AW-1:0] mt_base;  wire [AW:0] mt_len;  wire mt_wr, mt_rd;  wire [1:0] mt_mode;
  wire [31:0]   mt_seed;
  wire          mt_busy;
  wire [31:0]   mt_errs, mt_wcyc, mt_rcyc, mt_err_addr, mt_err_exp, mt_err_got;
  wire          calib_done, mt_err_led;

  ddr_ctrl #(.AW(AW), .UI_MHZ(UI_MHZ)) regs_ddr (
    .clk(user_clk), .rst(por),
    .req(r_req), .we(r_we), .addr(r_addr), .wdata(r_wdata), .rdata(ddr_rdata),
    .calib_raw(calib), .ui_rst_raw(ui_rst), .mt_busy_raw(mt_busy), .die_temp(die_temp),
    .mt_errs(mt_errs), .mt_wcyc(mt_wcyc), .mt_rcyc(mt_rcyc),
    .mt_err_addr(mt_err_addr), .mt_err_exp(mt_err_exp), .mt_err_got(mt_err_got),
    .mt_tog(mt_tog), .xcfg_mt_base(mt_base), .xcfg_mt_len(mt_len), .xcfg_mt_wr(mt_wr),
    .xcfg_mt_rd(mt_rd), .xcfg_mt_mode(mt_mode), .xcfg_mt_seed(mt_seed), .ddr_sys_rst(ddr_sys_rst),
    .max_payload(max_payload), .max_read_req(max_read_req), .bme(func_status[2]),
    .rq_tdata(rq_tdata), .rq_tkeep(rq_tkeep), .rq_tlast(rq_tlast), .rq_tuser(rq_tuser),
    .rq_tvalid(rq_tvalid), .rq_tready(rq_tready[0]),
    .rc_tdata(rc_tdata), .rc_tlast(rc_tlast), .rc_tvalid(rc_tvalid), .rc_tready(rc_tready),
    .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata),
    .r_valid(r_valid), .r_data(r_data), .r_pop(r_pop),
    .calib_done(calib_done), .mt_err_led(mt_err_led)
  );

  // memtest start: toggle from user_clk
  (* ASYNC_REG = "TRUE" *) reg [2:0] xs0_mtt = 3'b000;
  reg mtt_q = 1'b0;
  always @(posedge ui_clk) begin
    xs0_mtt <= {xs0_mtt[1:0], mt_tog};
    mtt_q <= xs0_mtt[2];
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
    .uclk(user_clk), .urst(ddr_urst),
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


`ifdef ILA
  // ILA probes on the MIG application interface (build.tcl ... ila, see ila.tcl)
  (* mark_debug = "true" *) wire        dbg_app_en      = app_en;
  (* mark_debug = "true" *) wire        dbg_app_rdy     = app_rdy;
  (* mark_debug = "true" *) wire        dbg_app_wdf_rdy = app_wdf_rdy;
  (* mark_debug = "true" *) wire        dbg_app_wren    = app_wdf_wren;
  (* mark_debug = "true" *) wire        dbg_app_rdv     = app_rd_valid;
  (* mark_debug = "true" *) wire        dbg_mt_sel      = mt_sel;
  (* mark_debug = "true" *) wire [2:0]  dbg_app_cmd     = app_cmd;
  (* mark_debug = "true" *) wire [15:0] dbg_app_addr    = app_addr[15:0];
  (* mark_debug = "true" *) wire [63:0] dbg_app_wdata   = app_wdf_data[63:0];
  (* mark_debug = "true" *) wire [63:0] dbg_app_wdata_h = app_wdf_data[255:192];
  (* mark_debug = "true" *) wire [63:0] dbg_app_rdata   = app_rd_data[63:0];
  (* mark_debug = "true" *) wire [63:0] dbg_app_rdata_h = app_rd_data[255:192];
`endif
  // ---------------- LEDs (silkscreen LED2..LED7 = led[0..5]) ----------------
  reg [27:0] hb = 28'd0;
  always @(posedge user_clk) hb <= hb + 28'd1;
  assign led = {mt_err_led, calib_done, spi_busy, user_lnk_up, perst_n, hb[27]};
endmodule
`default_nettype wire
