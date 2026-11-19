// KU5P board: PCIe endpoint (pcie4_uscale_plus, default Gen3 x8, 256-bit @ 250 MHz,
// 10ee:9021, BAR0 4 KB) with a BAR0-mapped SPI master for the configuration
// flash. Same register map as k7_pcie (see spi_regs.v), ID "KUPC".
// The same registers are reachable over JTAG through a JTAG-to-AXI master.
//
// UltraScale+ difference from the K7 design: the primary QSPI pins (D00-D03,
// FCS_B, CCLK) are dedicated bank-0 pins, so they have no top-level ports and
// are driven only through STARTUPE3 (DO/DTS/DI/FCSBO/USRCCLKO).
// Define DUAL_QSPI for boards with a second flash (x8 dual QSPI): that one
// sits on the multi-function pins D04-D07 / FCS2_B, which are user I/O.
// Define BOARD_LEDS to drive the six user LEDs.
`default_nettype none
module top #(
  parameter LANES  = 8,
  parameter DATA_W = 256        // must match axisten_if_width in gen_ip.tcl
) (
  input  wire              pcie_perst_n,
  input  wire              pcie_refclk_p,
  input  wire              pcie_refclk_n,
  input  wire [LANES-1:0]  pci_exp_rxp,
  input  wire [LANES-1:0]  pci_exp_rxn,
  output wire [LANES-1:0]  pci_exp_txp,
  output wire [LANES-1:0]  pci_exp_txn
`ifdef DUAL_QSPI
  ,
  output wire              flash2_cs_n,   // FCS2_B
  inout  wire [3:0]        flash2_dq      // D04..D07
`endif
`ifdef BOARD_LEDS
  ,
  output wire [5:0]        led
`endif
);
  localparam NDW = DATA_W / 32;
`ifdef DUAL_QSPI
  localparam [31:0] FEAT = 32'h1;
`else
  localparam [31:0] FEAT = 32'h0;
`endif

  // ---------------- clocks / resets ----------------
  wire refclk_gt, refclk_div2;
  IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) refclk_ibuf (
    .O(refclk_gt), .ODIV2(refclk_div2), .CEB(1'b0), .I(pcie_refclk_p), .IB(pcie_refclk_n));
  wire perst_n;
  IBUF perst_ibuf (.I(pcie_perst_n), .O(perst_n));

  wire user_clk, user_reset, user_lnk_up;

  // power-on reset for the register block (independent of the link state)
  reg [7:0] por_cnt = 8'd0;
  wire por = ~por_cnt[7];
  always @(posedge user_clk) if (por) por_cnt <= por_cnt + 8'd1;

  // ---------------- PCIe core ----------------
  wire [DATA_W-1:0] cq_tdata;  wire [NDW-1:0] cq_tkeep;  wire cq_tlast, cq_tvalid, cq_tready;
  wire [87:0]       cq_tuser;
  wire [DATA_W-1:0] cc_tdata;  wire [NDW-1:0] cc_tkeep;  wire cc_tlast, cc_tvalid;  wire [3:0] cc_tready;
  wire [5:0] ltssm;  wire [1:0] cur_speed;  wire [2:0] neg_width;
  wire       pwr_chg;

  // Unlisted inputs (RQ, MSI, cfg_mgmt, ...) are tied low by synthesis.
  pcie_ku pcie (
    .pci_exp_txp(pci_exp_txp), .pci_exp_txn(pci_exp_txn),
    .pci_exp_rxp(pci_exp_rxp), .pci_exp_rxn(pci_exp_rxn),
    .user_clk(user_clk), .user_reset(user_reset), .user_lnk_up(user_lnk_up),

    .s_axis_rq_tdata({DATA_W{1'b0}}), .s_axis_rq_tkeep({NDW{1'b0}}), .s_axis_rq_tlast(1'b0),
    .s_axis_rq_tuser(62'd0), .s_axis_rq_tvalid(1'b0), .s_axis_rq_tready(),
    .m_axis_rc_tdata(), .m_axis_rc_tkeep(), .m_axis_rc_tlast(), .m_axis_rc_tuser(),
    .m_axis_rc_tvalid(), .m_axis_rc_tready(1'b1),

    .m_axis_cq_tdata(cq_tdata), .m_axis_cq_tkeep(cq_tkeep), .m_axis_cq_tlast(cq_tlast),
    .m_axis_cq_tuser(cq_tuser), .m_axis_cq_tvalid(cq_tvalid), .m_axis_cq_tready(cq_tready),
    .s_axis_cc_tdata(cc_tdata), .s_axis_cc_tkeep(cc_tkeep), .s_axis_cc_tlast(cc_tlast),
    .s_axis_cc_tuser(33'd0), .s_axis_cc_tvalid(cc_tvalid), .s_axis_cc_tready(cc_tready),

    .pcie_cq_np_req(2'b11),          // no NP flow control from the user side
    .pcie_cq_np_req_count(),

    .cfg_ltssm_state(ltssm), .cfg_current_speed(cur_speed), .cfg_negotiated_width(neg_width),
    .cfg_dsn(64'h0000_0002_0000_0EE1),
    .cfg_link_training_enable(1'b1),
    .cfg_config_space_enable(1'b1),
    .cfg_power_state_change_interrupt(pwr_chg), .cfg_power_state_change_ack(pwr_chg),
    .cfg_err_cor_in(1'b0), .cfg_err_uncor_in(1'b0), .cfg_flr_done(4'd0),
    .cfg_interrupt_int(4'd0), .cfg_interrupt_pending(4'd0), .cfg_interrupt_sent(),
    .cfg_hot_reset_in(1'b0), .cfg_req_pm_transition_l23_ready(1'b0),

    .sys_clk(refclk_div2), .sys_clk_gt(refclk_gt), .sys_reset(perst_n),   // sys_reset is PERST#, active low
    .phy_rdy_out()
  );

  // ---------------- PCIe target ----------------
  wire p_req, p_we;  wire [11:2] p_addr;  wire [31:0] p_wdata;
  wire        bus_ack;  wire [31:0] bus_rdata;
  reg         ack_to_pcie;

  pcie_cq_pio #(.DATA_W(DATA_W)) pio (
    .clk(user_clk), .rst(user_reset),
    .cq_tdata(cq_tdata), .cq_tlast(cq_tlast), .cq_tvalid(cq_tvalid), .cq_tready(cq_tready),
    .cq_tuser(cq_tuser),
    .cc_tdata(cc_tdata), .cc_tkeep(cc_tkeep), .cc_tlast(cc_tlast), .cc_tvalid(cc_tvalid),
    .cc_tready(cc_tready[0]),
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

  // ---------------- SPI registers ----------------
  wire spi_sck, spi_cs_n, spi_mosi, spi_miso, spi_busy, spi_sel;
  // LINK: [15] link up, [14:12] negotiated width (0=x1 1=x2 2=x4 3=x8),
  //       [9:8] speed (0=2.5 1=5 2=8 GT/s), [5:0] LTSSM
  wire [31:0] link_status = {16'd0, user_lnk_up, neg_width, 2'b00, cur_speed, 2'b00, ltssm};

  // user_clk is 250 MHz here: reset SCK half period 8 -> 15.6 MHz (as on the K7)
  spi_regs #(.ID(32'h4B555043), .VERSION(32'h00020000), .FEAT(FEAT), .HALF_RESET(8'd8)) regs (
    .clk(user_clk), .rst(por),
    .req(r_req), .we(r_we), .addr(r_addr), .wdata(r_wdata), .ack(bus_ack), .rdata(bus_rdata),
    .link_status(link_status),
    .spi_sck(spi_sck), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
    .spi_sel(spi_sel), .busy_o(spi_busy)
  );

  // ---------------- primary flash via STARTUPE3 ----------------
  reg  cs0_q = 1'b1, mosi_q = 1'b1;
  wire [3:0] sdi;
  always @(posedge user_clk) begin
    cs0_q  <= spi_cs_n | spi_sel;
    mosi_q <= spi_mosi;
  end

  STARTUPE3 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) startup (
    .CFGCLK(), .CFGMCLK(), .EOS(), .PREQ(),
    .DI(sdi),                          // D00..D03 inputs
    .DO({2'b11, 1'b1, mosi_q}),        // D00 = MOSI, D02 = WP#, D03 = HOLD#/RESET#
    .DTS(4'b0010),                     // D01 (MISO) tristated, others driven
    .FCSBO(cs0_q), .FCSBTS(1'b0),
    .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
    .USRCCLKO(spi_sck), .USRCCLKTS(1'b0),
    .USRDONEO(1'b1), .USRDONETS(1'b1)
  );

  reg miso0_q;
  always @(posedge user_clk) miso0_q <= sdi[1];

`ifdef DUAL_QSPI
  // ---------------- second flash on D04..D07 / FCS2_B (shares CCLK) ----------------
  (* IOB = "TRUE" *) reg cs1_q = 1'b1, mosi1_q = 1'b1;
  (* IOB = "TRUE" *) reg miso1_q;
  always @(posedge user_clk) begin
    cs1_q   <= spi_cs_n | ~spi_sel;
    mosi1_q <= spi_mosi;
    miso1_q <= flash2_dq[1];
  end
  assign flash2_cs_n  = cs1_q;
  assign flash2_dq[0] = mosi1_q;
  assign flash2_dq[1] = 1'bz;
  assign flash2_dq[2] = 1'b1;
  assign flash2_dq[3] = 1'b1;
  assign spi_miso = spi_sel ? miso1_q : miso0_q;
`else
  assign spi_miso = miso0_q;
`endif

`ifdef BOARD_LEDS
  reg [27:0] hb = 28'd0;
  always @(posedge user_clk) hb <= hb + 28'd1;
  // LED2..LED7 on the silkscreen = led[0..5]
  assign led = {2'b00, spi_busy, user_lnk_up, perst_n, hb[27]};
`endif
endmodule
`default_nettype wire
