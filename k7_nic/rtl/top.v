// k7_nic: PCIe Gen2 x1 endpoint with a BAR0-mapped SPI master for the configuration
// flash, plus 10GBASE-R on both SFP+ cages (eth10g.v). The registers (including
// 10G status) are reachable over JTAG through a JTAG-to-AXI master as well.
//
// GTX use: PCIe lane 0 on GTXE2_CHANNEL_X0Y3 (quad 115, CPLL, refclk H6/H5);
// SFP A on X0Y7 (RX B6/B5), SFP B on X0Y6 (RX C4/C3) (quad 116, QPLL, refclk F6/F5).
//
// LEDs: 0 heartbeat (sys clk)  1 PCIe link up  2 QPLL lock
//       3 SFP A block lock     4 SFP B block lock  5 flash SPI busy
`default_nettype none
module top (
  input  wire       sys_clk,        // 100 MHz board oscillator
  output wire [5:0] led,

  input  wire       sfp_refclk_p, sfp_refclk_n,
  input  wire       sfp_a_rx_p, sfp_a_rx_n,
  output wire       sfp_a_tx_p, sfp_a_tx_n,
  output wire       sfp_a_tx_disable,
  input  wire       sfp_b_rx_p, sfp_b_rx_n,
  output wire       sfp_b_tx_p, sfp_b_tx_n,
  output wire       sfp_b_tx_disable,

  input  wire       pcie_perst_n,
  input  wire       pcie_refclk_p,
  input  wire       pcie_refclk_n,
  input  wire [0:0] pci_exp_rxp,
  input  wire [0:0] pci_exp_rxn,
  output wire [0:0] pci_exp_txp,
  output wire [0:0] pci_exp_txn,

  output wire       flash_cs_n,     // FCS_B
  inout  wire [3:0] flash_dq        // D00..D03
);
  // ---------------- clocks / resets ----------------
  wire refclk;
  IBUFDS_GTE2 refclk_ibuf (.O(refclk), .ODIV2(), .CEB(1'b0), .I(pcie_refclk_p), .IB(pcie_refclk_n));
  wire perst_n;
  IBUF perst_ibuf (.I(pcie_perst_n), .O(perst_n));

  wire user_clk, user_reset, user_lnk_up;

  // power-on reset for the register block (independent of the link state)
  reg [7:0] por_cnt = 8'd0;
  wire por = ~por_cnt[7];
  always @(posedge user_clk) if (por) por_cnt <= por_cnt + 8'd1;

  // ---------------- PCIe core ----------------
  wire [63:0] rx_tdata;  wire [7:0] rx_tkeep;  wire rx_tlast, rx_tvalid, rx_tready;  wire [21:0] rx_tuser;
  wire [63:0] tx_tdata;  wire [7:0] tx_tkeep;  wire tx_tlast, tx_tvalid, tx_tready;
  wire [7:0] cfg_bus;  wire [4:0] cfg_dev;  wire [2:0] cfg_fn;
  wire [15:0] cfg_lstatus;
  wire [5:0] ltssm;  wire sel_rate;  wire [1:0] sel_width;  wire cfg_to_turnoff;
  reg turnoff_ok = 1'b0;
  always @(posedge user_clk) turnoff_ok <= cfg_to_turnoff;

  pcie_x1 pcie (
    .pci_exp_txp(pci_exp_txp), .pci_exp_txn(pci_exp_txn),
    .pci_exp_rxp(pci_exp_rxp), .pci_exp_rxn(pci_exp_rxn),
    .int_pclk_out_slave(), .int_pipe_rxusrclk_out(), .int_rxoutclk_out(), .int_dclk_out(),
    .int_mmcm_lock_out(), .int_userclk1_out(), .int_userclk2_out(), .int_oobclk_out(),
    .int_qplllock_out(), .int_qplloutclk_out(), .int_qplloutrefclk_out(), .int_pclk_sel_slave(1'b0),
    .user_clk_out(user_clk), .user_reset_out(user_reset), .user_lnk_up(user_lnk_up), .user_app_rdy(),
    .tx_buf_av(), .tx_cfg_req(), .tx_err_drop(),
    .s_axis_tx_tready(tx_tready), .s_axis_tx_tdata(tx_tdata), .s_axis_tx_tkeep(tx_tkeep),
    .s_axis_tx_tlast(tx_tlast), .s_axis_tx_tvalid(tx_tvalid), .s_axis_tx_tuser(4'b0),
    .tx_cfg_gnt(1'b1),
    .m_axis_rx_tdata(rx_tdata), .m_axis_rx_tkeep(rx_tkeep), .m_axis_rx_tlast(rx_tlast),
    .m_axis_rx_tvalid(rx_tvalid), .m_axis_rx_tready(rx_tready), .m_axis_rx_tuser(rx_tuser),
    .rx_np_ok(1'b1), .rx_np_req(1'b1),
    .fc_cpld(), .fc_cplh(), .fc_npd(), .fc_nph(), .fc_pd(), .fc_ph(), .fc_sel(3'b0),
    .cfg_mgmt_do(), .cfg_mgmt_rd_wr_done(),
    .cfg_status(), .cfg_command(), .cfg_dstatus(), .cfg_dcommand(), .cfg_lstatus(cfg_lstatus),
    .cfg_lcommand(), .cfg_dcommand2(), .cfg_pcie_link_state(),
    .cfg_pmcsr_pme_en(), .cfg_pmcsr_powerstate(), .cfg_pmcsr_pme_status(), .cfg_received_func_lvl_rst(),
    .cfg_mgmt_di(32'd0), .cfg_mgmt_byte_en(4'd0), .cfg_mgmt_dwaddr(10'd0), .cfg_mgmt_wr_en(1'b0),
    .cfg_mgmt_rd_en(1'b0), .cfg_mgmt_wr_readonly(1'b0),
    .cfg_err_ecrc(1'b0), .cfg_err_ur(1'b0), .cfg_err_cpl_timeout(1'b0), .cfg_err_cpl_unexpect(1'b0),
    .cfg_err_cpl_abort(1'b0), .cfg_err_posted(1'b0), .cfg_err_cor(1'b0), .cfg_err_atomic_egress_blocked(1'b0),
    .cfg_err_internal_cor(1'b0), .cfg_err_malformed(1'b0), .cfg_err_mc_blocked(1'b0), .cfg_err_poisoned(1'b0),
    .cfg_err_norecovery(1'b0), .cfg_err_tlp_cpl_header(48'd0), .cfg_err_cpl_rdy(), .cfg_err_locked(1'b0),
    .cfg_err_acs(1'b0), .cfg_err_internal_uncor(1'b0),
    .cfg_trn_pending(1'b0), .cfg_pm_halt_aspm_l0s(1'b0), .cfg_pm_halt_aspm_l1(1'b0),
    .cfg_pm_force_state_en(1'b0), .cfg_pm_force_state(2'b00), .cfg_dsn(64'h0000_0001_0000_0EE1),
    .cfg_interrupt(1'b0), .cfg_interrupt_rdy(), .cfg_interrupt_assert(1'b0), .cfg_interrupt_di(8'd0),
    .cfg_interrupt_do(), .cfg_interrupt_mmenable(), .cfg_interrupt_msienable(), .cfg_interrupt_msixenable(),
    .cfg_interrupt_msixfm(), .cfg_interrupt_stat(1'b0), .cfg_pciecap_interrupt_msgnum(5'd0),
    .cfg_to_turnoff(cfg_to_turnoff), .cfg_turnoff_ok(turnoff_ok),
    .cfg_bus_number(cfg_bus), .cfg_device_number(cfg_dev), .cfg_function_number(cfg_fn),
    .cfg_pm_wake(1'b0), .cfg_pm_send_pme_to(1'b0),
    .cfg_ds_bus_number(8'd0), .cfg_ds_device_number(5'd0), .cfg_ds_function_number(3'd0),
    .cfg_mgmt_wr_rw1c_as_rw(1'b0),
    .cfg_msg_received(), .cfg_msg_data(), .cfg_bridge_serr_en(), .cfg_slot_control_electromech_il_ctl_pulse(),
    .cfg_root_control_syserr_corr_err_en(), .cfg_root_control_syserr_non_fatal_err_en(),
    .cfg_root_control_syserr_fatal_err_en(), .cfg_root_control_pme_int_en(),
    .cfg_aer_rooterr_corr_err_reporting_en(), .cfg_aer_rooterr_non_fatal_err_reporting_en(),
    .cfg_aer_rooterr_fatal_err_reporting_en(), .cfg_aer_rooterr_corr_err_received(),
    .cfg_aer_rooterr_non_fatal_err_received(), .cfg_aer_rooterr_fatal_err_received(),
    .cfg_msg_received_err_cor(), .cfg_msg_received_err_non_fatal(), .cfg_msg_received_err_fatal(),
    .cfg_msg_received_pm_as_nak(), .cfg_msg_received_pm_pme(), .cfg_msg_received_pme_to_ack(),
    .cfg_msg_received_assert_int_a(), .cfg_msg_received_assert_int_b(), .cfg_msg_received_assert_int_c(),
    .cfg_msg_received_assert_int_d(), .cfg_msg_received_deassert_int_a(), .cfg_msg_received_deassert_int_b(),
    .cfg_msg_received_deassert_int_c(), .cfg_msg_received_deassert_int_d(), .cfg_msg_received_setslotpowerlimit(),
    .pl_directed_link_change(2'b00), .pl_directed_link_width(2'b00), .pl_directed_link_speed(1'b0),
    .pl_directed_link_auton(1'b0), .pl_upstream_prefer_deemph(1'b1),
    .pl_sel_lnk_rate(sel_rate), .pl_sel_lnk_width(sel_width), .pl_ltssm_state(ltssm),
    .pl_lane_reversal_mode(), .pl_phy_lnk_up(), .pl_tx_pm_state(), .pl_rx_pm_state(),
    .pl_link_upcfg_cap(), .pl_link_gen2_cap(), .pl_link_partner_gen2_supported(), .pl_initial_link_width(),
    .pl_directed_change_done(), .pl_received_hot_rst(), .pl_transmit_hot_rst(1'b0),
    .pl_downstream_deemph_source(1'b0),
    .cfg_err_aer_headerlog(128'd0), .cfg_aer_interrupt_msgnum(5'd0), .cfg_err_aer_headerlog_set(),
    .cfg_aer_ecrc_check_en(), .cfg_aer_ecrc_gen_en(), .cfg_vc_tcvc_map(),
    .sys_clk(refclk), .sys_rst_n(perst_n),
    .pcie_drp_clk(1'b1), .pcie_drp_en(1'b0), .pcie_drp_we(1'b0), .pcie_drp_addr(9'd0),
    .pcie_drp_di(16'd0), .pcie_drp_do(), .pcie_drp_rdy()
  );

  // ---------------- PCIe target ----------------
  wire p_req, p_we;  wire [11:2] p_addr;  wire [31:0] p_wdata;
  wire        bus_ack;  wire [31:0] bus_rdata;
  reg         ack_to_pcie;

  pcie_pio pio (
    .clk(user_clk), .rst(user_reset),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid),
    .rx_tready(rx_tready), .rx_tuser(rx_tuser),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
    .completer_id({cfg_bus, cfg_dev, cfg_fn}),
    .bus_req(p_req), .bus_we(p_we), .bus_addr(p_addr), .bus_wdata(p_wdata),
    .bus_ack(bus_ack & ack_to_pcie), .bus_rdata(bus_rdata)
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

  // AXI-Lite to register bus. A request accepted from AXI stays pending
  // (a_pend) until a cycle where PCIe does not issue; PCIe has priority.
  localparam A_IDLE = 2'd0, A_WAIT_W = 2'd1, A_WAIT_R = 2'd2;
  reg [1:0]  ast = A_IDLE;
  reg        a_pend = 1'b0, a_we = 1'b0, a_issued = 1'b0;
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

  // The register block acks exactly one cycle after req, so track who asked.
  wire        r_req   = p_req | a_go;
  wire        r_we    = p_req ? p_we : a_we;
  wire [11:2] r_addr  = p_req ? p_addr : a_addr_q[11:2];
  wire [31:0] r_wdata = p_req ? p_wdata : a_wdata_q;
  always @(posedge user_clk) ack_to_pcie <= p_req;

  // ---------------- SPI registers + flash pins ----------------
  wire spi_sck, spi_cs_n, spi_mosi, spi_miso, spi_busy;
  wire [31:0] link_status = {16'd0, user_lnk_up, 1'b0, sel_width, 3'd0, sel_rate, 2'b00, ltssm};

  // ---------------- 10GBASE-R on both SFP cages ----------------
  wire [5:0]   eth_led;
  wire [31:0]  eth_stat;
  wire [255:0] eth_rates;
  wire         eth_rates_tgl;

  eth10g eth (
    .clk(sys_clk), .led(eth_led),
    .stat(eth_stat), .rates(eth_rates), .rates_tgl(eth_rates_tgl),
    .sfp_refclk_p(sfp_refclk_p), .sfp_refclk_n(sfp_refclk_n),
    .sfp_a_rx_p(sfp_a_rx_p), .sfp_a_rx_n(sfp_a_rx_n),
    .sfp_a_tx_p(sfp_a_tx_p), .sfp_a_tx_n(sfp_a_tx_n), .sfp_a_tx_disable(sfp_a_tx_disable),
    .sfp_b_rx_p(sfp_b_rx_p), .sfp_b_rx_n(sfp_b_rx_n),
    .sfp_b_tx_p(sfp_b_tx_p), .sfp_b_tx_n(sfp_b_tx_n), .sfp_b_tx_disable(sfp_b_tx_disable)
  );

  // sys_clk -> user_clk. Status bits are independent flags: plain 2-flop sync.
  // Rates hold for 1 s after rates_tgl flips: capture them once the toggle has
  // crossed (by then they are long stable).
  (* ASYNC_REG = "TRUE" *) reg [31:0] eth_stat_s1 = 0, eth_stat_s2 = 0;
  (* ASYNC_REG = "TRUE" *) reg [2:0]  eth_tgl_s = 0;
  reg [255:0] eth_rates_u = 0;
  always @(posedge user_clk) begin
    eth_stat_s1 <= eth_stat;
    eth_stat_s2 <= eth_stat_s1;
    eth_tgl_s   <= {eth_tgl_s[1:0], eth_rates_tgl};
    if (eth_tgl_s[2] != eth_tgl_s[1]) eth_rates_u <= eth_rates;
  end

  spi_regs regs (
    .clk(user_clk), .rst(por),
    .req(r_req), .we(r_we), .addr(r_addr), .wdata(r_wdata), .ack(bus_ack), .rdata(bus_rdata),
    .link_status(link_status),
    .eth_stat(eth_stat_s2), .eth_rates(eth_rates_u),
    .spi_sck(spi_sck), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .busy_o(spi_busy)
  );

  STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) startup (
    .CFGCLK(), .CFGMCLK(), .EOS(), .PREQ(),
    .CLK(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
    .USRCCLKO(spi_sck), .USRCCLKTS(1'b0), .USRDONEO(1'b1), .USRDONETS(1'b1)
  );

  (* IOB = "TRUE" *) reg cs_q = 1'b1, mosi_q = 1'b1;
  (* IOB = "TRUE" *) reg miso_q;
  always @(posedge user_clk) begin
    cs_q <= spi_cs_n;
    mosi_q <= spi_mosi;
    miso_q <= flash_dq[1];
  end
  assign flash_cs_n  = cs_q;
  assign flash_dq[0] = mosi_q;
  assign flash_dq[1] = 1'bz;
  assign flash_dq[2] = 1'b1;   // WP#
  assign flash_dq[3] = 1'b1;   // HOLD# / RESET#
  assign spi_miso = miso_q;

  // ---------------- LEDs ----------------
  reg [26:0] hb_sys = 27'd0;
  always @(posedge sys_clk) hb_sys <= hb_sys + 27'd1;
  reg [26:0] hb_usr = 27'd0;
  always @(posedge user_clk) hb_usr <= hb_usr + 27'd1;
  assign led = {spi_busy, eth_led[4], eth_led[3], eth_led[1], user_lnk_up, hb_sys[26]};
endmodule
`default_nettype wire
