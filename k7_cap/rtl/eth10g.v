// 10GBASE-R PCS bring-up on both SFP+ cages of the xc7k325t board, license-free:
//   GTX from the free 7-series GT wizard (raw 64-bit, 10.3125 Gb/s, QPLL),
//   fabric gearbox (gearbox.v), and the open-source PCS eth_phy_10g from
//   verilog-ethernet (MIT, rtl/verilog-ethernet). In k7_udp SFP A carries the XGMII
//   of a MAC (udp_counter.v, ports *_a); SFP B transmits XGMII idle (loopback check).
//
// LEDs: 0 heartbeat (100 MHz sys clk)   1 QPLL lock
//       2 TX + RX reset done (A and B)  3 SFP A block lock
//       4 SFP B block lock              5 heartbeat from the TX PCS clock (156.25 MHz avg)
// JTAG: status_vio (read_status.tcl).
// In k7_nic this is a submodule of top.v; status also goes out (clk domain) for the
// PCIe BAR0 registers. `stat` and `rates` are valid in the clk domain; `rates_tgl`
// flips on the clk edge where the per-second rates update (they then hold for 1 s).
`default_nettype none
module eth10g (
    input  wire       clk,            // 100 MHz
    output wire [5:0] led,
    output wire [31:0]  stat,         // {st_b, st_a, misc}
    output wire [255:0] rates,        // {r_rf_b, r_lf_b, r_idle_b, r_rf_a, r_lf_a, r_idle_a, hz_rx_a, hz_tx}
    output reg          rates_tgl = 1'b0,
    input  wire       sfp_refclk_p, sfp_refclk_n,
    input  wire       sfp_a_rx_p, sfp_a_rx_n,
    output wire       sfp_a_tx_p, sfp_a_tx_n,
    output wire       sfp_a_tx_disable,
    input  wire       sfp_b_rx_p, sfp_b_rx_n,
    output wire       sfp_b_tx_p, sfp_b_tx_n,
    output wire       sfp_b_tx_disable,
    // SFP A XGMII for the MAC (k7_udp): TX side on tx_pcs_clk, RX side on rx_pcs_clk_a
    output wire        tx_pcs_clk_o,
    output wire        tx_pcs_rst_o,
    input  wire [63:0] xgmii_txd_a,
    input  wire [7:0]  xgmii_txc_a,
    output wire        rx_pcs_clk_a,
    output wire        rx_pcs_rst_a,
    output wire [63:0] xgmii_rxd_a,
    output wire [7:0]  xgmii_rxc_a
);
    // ---------------- power-on reset (~10 ms) + VIO controls ----------------
    reg [19:0] por_cnt = 0;
    reg        por     = 1'b1;
    always @(posedge clk) begin
        if (por_cnt != 20'hFFFFF) por_cnt <= por_cnt + 1'b1;
        por <= (por_cnt != 20'hFFFFF);
    end
    wire       vio_rst;
    wire       vio_bitrev;     // reverse bit order of each 64-bit GT word (debug)
    wire [1:0] vio_rxpol, vio_txpol;
    wire       reset = por | vio_rst;

    assign sfp_a_tx_disable = 1'b0;
    assign sfp_b_tx_disable = 1'b0;

    // ---------------- reference clock, QPLL ----------------
    wire refclk, refclk_bufg;
    IBUFDS_GTE2 u_refbuf (.I(sfp_refclk_p), .IB(sfp_refclk_n), .CEB(1'b0), .O(refclk), .ODIV2());
    BUFG u_refbufg (.I(refclk), .O(refclk_bufg));

    wire qplllock, qpllrefclklost, qpllreset_req, qplloutclk, qplloutrefclk;
    GTXE2_COMMON #(
        .SIM_RESET_SPEEDUP("FALSE"), .SIM_QPLLREFCLK_SEL(3'b001), .SIM_VERSION("4.0"),
        .BIAS_CFG(64'h0000040000001000), .COMMON_CFG(32'h00000000),
        .QPLL_CFG(27'h0680181), .QPLL_CLKOUT_CFG(4'b0000),
        .QPLL_COARSE_FREQ_OVRD(6'b010000), .QPLL_COARSE_FREQ_OVRD_EN(1'b0),
        .QPLL_CP(10'b0000011111), .QPLL_CP_MONITOR_EN(1'b0), .QPLL_DMONITOR_SEL(1'b0),
        .QPLL_FBDIV(10'b0101000000),      // N = 66: 156.25 MHz * 66 = 10.3125 GHz
        .QPLL_FBDIV_MONITOR_EN(1'b0), .QPLL_FBDIV_RATIO(1'b0),
        .QPLL_INIT_CFG(24'h000006), .QPLL_LOCK_CFG(16'h21E8), .QPLL_LPF(4'b1111),
        .QPLL_REFCLK_DIV(1)
    ) u_qpll (
        .DRPADDR(8'd0), .DRPCLK(1'b0), .DRPDI(16'd0), .DRPDO(), .DRPEN(1'b0), .DRPRDY(), .DRPWE(1'b0),
        .GTGREFCLK(1'b0), .GTNORTHREFCLK0(1'b0), .GTNORTHREFCLK1(1'b0),
        .GTREFCLK0(refclk), .GTREFCLK1(1'b0), .GTSOUTHREFCLK0(1'b0), .GTSOUTHREFCLK1(1'b0),
        .QPLLOUTCLK(qplloutclk), .QPLLOUTREFCLK(qplloutrefclk), .REFCLKOUTMONITOR(),
        .QPLLDMONITOR(), .QPLLFBCLKLOST(), .QPLLLOCK(qplllock), .QPLLLOCKDETCLK(clk),
        .QPLLLOCKEN(1'b1), .QPLLOUTRESET(1'b0), .QPLLPD(1'b0), .QPLLREFCLKLOST(qpllrefclklost),
        .QPLLREFCLKSEL(3'b001), .QPLLRESET(qpllreset_req | por), .QPLLRSVD1(16'd0), .QPLLRSVD2(5'b11111),
        .BGBYPASSB(1'b1), .BGMONITORENB(1'b1), .BGPDB(1'b1), .BGRCALOVRD(5'b11111),
        .PMARSVD(8'd0), .RCALENB(1'b1)
    );

    // ---------------- TX user clocks (from refclk: 322.27 / 161.13 MHz) ----------------
    wire txusrclk, txusrclk2, txclk2_raw, tx_mmcm_locked;
    usrclk_mmcm #(.CLKIN_PERIOD(6.400), .MULT(33.0), .DIV(4)) u_txmmcm (
        .clkin(refclk_bufg), .rst(por), .usrclk(txusrclk), .usrclk2(txusrclk2),
        .usrclk2_raw(txclk2_raw), .locked(tx_mmcm_locked));

    // ---------------- GTX channels (gt0 = SFP A, gt1 = SFP B) ----------------
    wire [1:0]  rxoutclk, rx_mmcm_rst, rx_mmcm_locked, rxresetdone, txresetdone;
    wire [1:0]  tx_fsm_done, rx_fsm_done;
    wire [1:0]  rxusrclk, rxusrclk2, rxclk2_raw;
    wire [63:0] rxdata0, rxdata1, txdata0, txdata1;
    wire [1:0]  block_lock;

    gtx10g u_gt (
        .sysclk_in(clk), .soft_reset_tx_in(reset), .soft_reset_rx_in(reset),
        .dont_reset_on_data_error_in(1'b0),
        .gt0_tx_fsm_reset_done_out(tx_fsm_done[0]), .gt0_rx_fsm_reset_done_out(rx_fsm_done[0]),
        .gt0_data_valid_in(block_lock[0]),
        .gt0_tx_mmcm_lock_in(tx_mmcm_locked), .gt0_tx_mmcm_reset_out(),
        .gt0_rx_mmcm_lock_in(rx_mmcm_locked[0]), .gt0_rx_mmcm_reset_out(rx_mmcm_rst[0]),
        .gt1_tx_fsm_reset_done_out(tx_fsm_done[1]), .gt1_rx_fsm_reset_done_out(rx_fsm_done[1]),
        .gt1_data_valid_in(block_lock[1]),
        .gt1_tx_mmcm_lock_in(tx_mmcm_locked), .gt1_tx_mmcm_reset_out(),
        .gt1_rx_mmcm_lock_in(rx_mmcm_locked[1]), .gt1_rx_mmcm_reset_out(rx_mmcm_rst[1]),

        .gt0_drpaddr_in(9'd0), .gt0_drpclk_in(clk), .gt0_drpdi_in(16'd0), .gt0_drpdo_out(),
        .gt0_drpen_in(1'b0), .gt0_drprdy_out(), .gt0_drpwe_in(1'b0),
        .gt0_dmonitorout_out(), .gt0_loopback_in(3'd0), .gt0_rxrate_in(3'd0),
        .gt0_eyescanreset_in(1'b0), .gt0_rxuserrdy_in(1'b1), .gt0_eyescandataerror_out(),
        .gt0_eyescantrigger_in(1'b0), .gt0_rxcdrhold_in(1'b0),
        .gt0_rxusrclk_in(rxusrclk[0]), .gt0_rxusrclk2_in(rxusrclk2[0]), .gt0_rxdata_out(rxdata0),
        .gt0_rxprbserr_out(), .gt0_rxprbssel_in(3'd0), .gt0_rxprbscntreset_in(1'b0),
        .gt0_gtxrxp_in(sfp_a_rx_p), .gt0_gtxrxn_in(sfp_a_rx_n),
        .gt0_rxbufreset_in(1'b0), .gt0_rxbufstatus_out(), .gt0_rxdfelpmreset_in(1'b0),
        .gt0_rxmonitorout_out(), .gt0_rxmonitorsel_in(2'd0), .gt0_rxratedone_out(),
        .gt0_rxoutclk_out(rxoutclk[0]), .gt0_rxoutclkfabric_out(),
        .gt0_gtrxreset_in(1'b0), .gt0_rxpcsreset_in(1'b0), .gt0_rxpmareset_in(1'b0),
        .gt0_rxlpmen_in(1'b0), .gt0_rxpolarity_in(vio_rxpol[0]), .gt0_rxslide_in(1'b0),
        .gt0_rxresetdone_out(rxresetdone[0]),
        .gt0_txpostcursor_in(5'd0), .gt0_txprecursor_in(5'd0),
        .gt0_gttxreset_in(1'b0), .gt0_txuserrdy_in(1'b1),
        .gt0_txusrclk_in(txusrclk), .gt0_txusrclk2_in(txusrclk2),
        .gt0_txprbsforceerr_in(1'b0), .gt0_txbufstatus_out(),
        .gt0_txdiffctrl_in(4'b1110), .gt0_txinhibit_in(1'b0), .gt0_txmaincursor_in(7'd0),
        .gt0_txdata_in(txdata0), .gt0_gtxtxn_out(sfp_a_tx_n), .gt0_gtxtxp_out(sfp_a_tx_p),
        .gt0_txoutclk_out(), .gt0_txoutclkfabric_out(), .gt0_txoutclkpcs_out(),
        .gt0_txpcsreset_in(1'b0), .gt0_txpmareset_in(1'b0), .gt0_txresetdone_out(txresetdone[0]),
        .gt0_txpolarity_in(vio_txpol[0]), .gt0_txprbssel_in(3'd0),

        .gt1_drpaddr_in(9'd0), .gt1_drpclk_in(clk), .gt1_drpdi_in(16'd0), .gt1_drpdo_out(),
        .gt1_drpen_in(1'b0), .gt1_drprdy_out(), .gt1_drpwe_in(1'b0),
        .gt1_dmonitorout_out(), .gt1_loopback_in(3'd0), .gt1_rxrate_in(3'd0),
        .gt1_eyescanreset_in(1'b0), .gt1_rxuserrdy_in(1'b1), .gt1_eyescandataerror_out(),
        .gt1_eyescantrigger_in(1'b0), .gt1_rxcdrhold_in(1'b0),
        .gt1_rxusrclk_in(rxusrclk[1]), .gt1_rxusrclk2_in(rxusrclk2[1]), .gt1_rxdata_out(rxdata1),
        .gt1_rxprbserr_out(), .gt1_rxprbssel_in(3'd0), .gt1_rxprbscntreset_in(1'b0),
        .gt1_gtxrxp_in(sfp_b_rx_p), .gt1_gtxrxn_in(sfp_b_rx_n),
        .gt1_rxbufreset_in(1'b0), .gt1_rxbufstatus_out(), .gt1_rxdfelpmreset_in(1'b0),
        .gt1_rxmonitorout_out(), .gt1_rxmonitorsel_in(2'd0), .gt1_rxratedone_out(),
        .gt1_rxoutclk_out(rxoutclk[1]), .gt1_rxoutclkfabric_out(),
        .gt1_gtrxreset_in(1'b0), .gt1_rxpcsreset_in(1'b0), .gt1_rxpmareset_in(1'b0),
        .gt1_rxlpmen_in(1'b0), .gt1_rxpolarity_in(vio_rxpol[1]), .gt1_rxslide_in(1'b0),
        .gt1_rxresetdone_out(rxresetdone[1]),
        .gt1_txpostcursor_in(5'd0), .gt1_txprecursor_in(5'd0),
        .gt1_gttxreset_in(1'b0), .gt1_txuserrdy_in(1'b1),
        .gt1_txusrclk_in(txusrclk), .gt1_txusrclk2_in(txusrclk2),
        .gt1_txprbsforceerr_in(1'b0), .gt1_txbufstatus_out(),
        .gt1_txdiffctrl_in(4'b1110), .gt1_txinhibit_in(1'b0), .gt1_txmaincursor_in(7'd0),
        .gt1_txdata_in(txdata1), .gt1_gtxtxn_out(sfp_b_tx_n), .gt1_gtxtxp_out(sfp_b_tx_p),
        .gt1_txoutclk_out(), .gt1_txoutclkfabric_out(), .gt1_txoutclkpcs_out(),
        .gt1_txpcsreset_in(1'b0), .gt1_txpmareset_in(1'b0), .gt1_txresetdone_out(txresetdone[1]),
        .gt1_txpolarity_in(vio_txpol[1]), .gt1_txprbssel_in(3'd0),

        .gt0_qplllock_in(qplllock), .gt0_qpllrefclklost_in(qpllrefclklost),
        .gt0_qpllreset_out(qpllreset_req),
        .gt0_qplloutclk_in(qplloutclk), .gt0_qplloutrefclk_in(qplloutrefclk)
    );

    // ---------------- RX user clocks per channel (from recovered RXOUTCLK) ----------------
    genvar g;
    generate for (g = 0; g < 2; g = g + 1) begin : rxclk
        wire rxoutclk_bufg;
        BUFG u_bufg (.I(rxoutclk[g]), .O(rxoutclk_bufg));
        usrclk_mmcm #(.CLKIN_PERIOD(3.103), .MULT(4.0), .DIV(1)) u_mmcm (
            .clkin(rxoutclk_bufg), .rst(rx_mmcm_rst[g] | por), .usrclk(rxusrclk[g]),
            .usrclk2(rxusrclk2[g]), .usrclk2_raw(rxclk2_raw[g]), .locked(rx_mmcm_locked[g]));
    end endgenerate

    // ---------------- TX: one gearbox timing shared by both channels ----------------
    wire tx_gb_rst;
    rst_sync u_txgbrst (.clk(txusrclk2), .arst(~(tx_mmcm_locked & tx_fsm_done[0] & tx_fsm_done[1])), .rst(tx_gb_rst));

    // Gated PCS clock: 32 of every 33 cycles of 161.13 MHz = 156.25 MHz average.
    wire tx_ce, tx_pcs_clk, tx_pcs_rst;
    BUFGCE u_txpcsbuf (.I(txclk2_raw), .CE(tx_ce), .O(tx_pcs_clk));
    rst_sync u_txpcsrst (.clk(tx_pcs_clk), .arst(tx_gb_rst), .rst(tx_pcs_rst));

    localparam [63:0] IDLE_D = 64'h0707070707070707;
    localparam [7:0]  IDLE_C = 8'hFF;

    // ---------------- per channel PCS ----------------
    wire [63:0] txw [0:1];
    wire [63:0] rxw [0:1];
    assign rxw[0] = rxdata0;
    assign rxw[1] = rxdata1;
    assign txdata0 = txw[0];
    assign txdata1 = txw[1];

    wire [1:0] rx_pcs_clk;
    wire [1:0] high_ber, rx_status_w, rx_rst_w;
    wire [7:0] rx_errs [0:1];
    wire [63:0] xgmii_rxd [0:1];
    wire [7:0]  xgmii_rxc [0:1];

    function [63:0] rev64; input [63:0] x; integer i;
        for (i = 0; i < 64; i = i + 1) rev64[i] = x[63-i];
    endfunction

    // bit-reverse control into the GT clock domains (static debug setting)
    (* ASYNC_REG = "TRUE" *) reg [1:0] bitrev_tx_s = 0;
    always @(posedge txusrclk2) bitrev_tx_s <= {bitrev_tx_s[0], vio_bitrev};

    generate for (g = 0; g < 2; g = g + 1) begin : ch
        // TX
        wire [63:0] tx_data;
        wire [1:0]  tx_hdr;
        wire [63:0] tx_word;
        // only channel 0's gearbox drives the BUFGCE; both run in lockstep from the same reset
        wire        ce_g;
        gearbox_tx u_gbtx (.clk(txusrclk2), .rst(tx_gb_rst), .blk({tx_data, tx_hdr}), .ce(ce_g), .word(tx_word));
        if (g == 0) begin : ce0
            assign tx_ce = ce_g;
        end
        assign txw[g] = bitrev_tx_s[1] ? rev64(tx_word) : tx_word;

        // RX
        wire rx_gb_rst;
        rst_sync u_rxgbrst (.clk(rxusrclk2[g]), .arst(~(rx_mmcm_locked[g] & rxresetdone[g])), .rst(rx_gb_rst));
        (* ASYNC_REG = "TRUE" *) reg [1:0] bitrev_rx_s = 0;
        always @(posedge rxusrclk2[g]) bitrev_rx_s <= {bitrev_rx_s[0], vio_bitrev};
        reg  [63:0] rx_word = 0;
        always @(posedge rxusrclk2[g]) rx_word <= bitrev_rx_s[1] ? rev64(rxw[g]) : rxw[g];

        wire [65:0] rx_blk;
        wire        rx_valid, bitslip;
        reg         bitslip_d = 1'b0;
        always @(posedge rxusrclk2[g]) bitslip_d <= bitslip;
        gearbox_rx u_gbrx (.clk(rxusrclk2[g]), .rst(rx_gb_rst), .word(rx_word),
                           .slip(bitslip & ~bitslip_d), .blk(rx_blk), .valid(rx_valid));

        BUFGCE u_rxpcsbuf (.I(rxclk2_raw[g]), .CE(rx_valid), .O(rx_pcs_clk[g]));
        wire rx_pcs_rst;
        rst_sync u_rxpcsrst (.clk(rx_pcs_clk[g]), .arst(rx_gb_rst), .rst(rx_pcs_rst));
        assign rx_rst_w[g] = rx_pcs_rst;

        eth_phy_10g #(
            .DATA_WIDTH(64), .BIT_REVERSE(0), .SCRAMBLER_DISABLE(0), .PRBS31_ENABLE(0),
            .TX_SERDES_PIPELINE(1), .RX_SERDES_PIPELINE(1),
            .BITSLIP_HIGH_CYCLES(1), .BITSLIP_LOW_CYCLES(8), .COUNT_125US(125000/6.4)
        ) u_phy (
            .rx_clk(rx_pcs_clk[g]), .rx_rst(rx_pcs_rst), .tx_clk(tx_pcs_clk), .tx_rst(tx_pcs_rst),
            .xgmii_txd(g == 0 ? xgmii_txd_a : IDLE_D), .xgmii_txc(g == 0 ? xgmii_txc_a : IDLE_C),
            .xgmii_rxd(xgmii_rxd[g]), .xgmii_rxc(xgmii_rxc[g]),
            .serdes_tx_data(tx_data), .serdes_tx_hdr(tx_hdr),
            .serdes_rx_data(rx_blk[65:2]), .serdes_rx_hdr(rx_blk[1:0]),
            .serdes_rx_bitslip(bitslip), .serdes_rx_reset_req(),
            .tx_bad_block(), .rx_error_count(rx_errs[g][6:0]), .rx_bad_block(),
            .rx_sequence_error(), .rx_block_lock(block_lock[g]), .rx_high_ber(high_ber[g]),
            .rx_status(rx_status_w[g]),
            .cfg_tx_prbs31_enable(1'b0), .cfg_rx_prbs31_enable(1'b0)
        );
        assign rx_errs[g][7] = 1'b0;
    end endgenerate

    assign tx_pcs_clk_o = tx_pcs_clk;
    assign tx_pcs_rst_o = tx_pcs_rst;
    assign rx_pcs_clk_a = rx_pcs_clk[0];
    assign rx_pcs_rst_a = rx_rst_w[0];
    assign xgmii_rxd_a  = xgmii_rxd[0];
    assign xgmii_rxc_a  = xgmii_rxc[0];

    // ---------------- RX classification (per channel, PCS clock domain) ----------------
    function is_lf; input [63:0] d; input [7:0] c;
        is_lf = (c[0] && d[7:0]==8'h9C && d[31:8]==24'h010000) || (c[4] && d[39:32]==8'h9C && d[63:40]==24'h010000);
    endfunction
    function is_rf; input [63:0] d; input [7:0] c;
        is_rf = (c[0] && d[7:0]==8'h9C && d[31:8]==24'h020000) || (c[4] && d[39:32]==8'h9C && d[63:40]==24'h020000);
    endfunction

    reg ev_idle_a, ev_lf_a, ev_rf_a, ev_idle_b, ev_lf_b, ev_rf_b;
    always @(posedge rx_pcs_clk[0]) begin
        ev_idle_a <= (xgmii_rxc[0] == IDLE_C) && (xgmii_rxd[0] == IDLE_D);
        ev_lf_a   <= is_lf(xgmii_rxd[0], xgmii_rxc[0]);
        ev_rf_a   <= is_rf(xgmii_rxd[0], xgmii_rxc[0]);
    end
    always @(posedge rx_pcs_clk[1]) begin
        ev_idle_b <= (xgmii_rxc[1] == IDLE_C) && (xgmii_rxd[1] == IDLE_D);
        ev_lf_b   <= is_lf(xgmii_rxd[1], xgmii_rxc[1]);
        ev_rf_b   <= is_rf(xgmii_rxd[1], xgmii_rxc[1]);
    end

    // ---------------- per-second rates ----------------
    reg [26:0] sec_cnt = 0;
    reg        sec_tick = 0;
    always @(posedge clk) begin
        sec_tick <= (sec_cnt == 27'd99_999_999);
        sec_cnt  <= (sec_cnt == 27'd99_999_999) ? 27'd0 : sec_cnt + 1'b1;
    end

    wire [31:0] hz_tx, hz_rx_a, r_idle_a, r_lf_a, r_rf_a, r_idle_b, r_lf_b, r_rf_b;
    rate_meter m0 (.cclk(tx_pcs_clk),    .ev(1'b1),      .sclk(clk), .tick(sec_tick), .rate(hz_tx));
    rate_meter m1 (.cclk(rx_pcs_clk[0]), .ev(1'b1),      .sclk(clk), .tick(sec_tick), .rate(hz_rx_a));
    rate_meter m2 (.cclk(rx_pcs_clk[0]), .ev(ev_idle_a), .sclk(clk), .tick(sec_tick), .rate(r_idle_a));
    rate_meter m3 (.cclk(rx_pcs_clk[0]), .ev(ev_lf_a),   .sclk(clk), .tick(sec_tick), .rate(r_lf_a));
    rate_meter m4 (.cclk(rx_pcs_clk[0]), .ev(ev_rf_a),   .sclk(clk), .tick(sec_tick), .rate(r_rf_a));
    rate_meter m5 (.cclk(rx_pcs_clk[1]), .ev(ev_idle_b), .sclk(clk), .tick(sec_tick), .rate(r_idle_b));
    rate_meter m6 (.cclk(rx_pcs_clk[1]), .ev(ev_lf_b),   .sclk(clk), .tick(sec_tick), .rate(r_lf_b));
    rate_meter m7 (.cclk(rx_pcs_clk[1]), .ev(ev_rf_b),   .sclk(clk), .tick(sec_tick), .rate(r_rf_b));

    // ---------------- status sync to clk ----------------
    wire [15:0] misc_raw = {2'b00, rx_mmcm_locked, rxresetdone, txresetdone,
                            rx_fsm_done, tx_fsm_done, tx_mmcm_locked, qplllock};
    wire [7:0]  st_a_raw = {rx_errs[0][4:0], rx_status_w[0], high_ber[0], block_lock[0]};
    wire [7:0]  st_b_raw = {rx_errs[1][4:0], rx_status_w[1], high_ber[1], block_lock[1]};
    (* ASYNC_REG = "TRUE" *) reg [31:0] st_s1 = 0, st_s2 = 0;
    always @(posedge clk) begin
        st_s1 <= {st_b_raw, st_a_raw, misc_raw};
        st_s2 <= st_s1;
    end
    wire [15:0] misc = st_s2[15:0];
    // misc: [0] qplllock [1] tx mmcm locked [3:2] tx_fsm_done B,A [5:4] rx_fsm_done B,A
    //       [7:6] txresetdone B,A [9:8] rxresetdone B,A [11:10] rx mmcm locked B,A
    wire [7:0]  st_a = st_s2[23:16];   // [0] block lock [1] high BER [2] rx_status [7:3] error count
    wire [7:0]  st_b = st_s2[31:24];

    // ---------------- LEDs ----------------
    reg [25:0] hb = 0;
    always @(posedge clk) hb <= hb + 1'b1;
    reg [26:0] hb_tx = 0;
    always @(posedge tx_pcs_clk) hb_tx <= hb_tx + 1'b1;

    assign led[0] = hb[25];
    assign led[1] = misc[0];
    assign led[2] = &misc[9:6];
    assign led[3] = st_a[0];
    assign led[4] = st_b[0];
    assign led[5] = hb_tx[26];

    assign stat  = st_s2;
    assign rates = {r_rf_b, r_lf_b, r_idle_b, r_rf_a, r_lf_a, r_idle_a, hz_rx_a, hz_tx};
    always @(posedge clk) if (sec_tick) rates_tgl <= ~rates_tgl;

    status_vio u_vio (
        .clk(clk),
        .probe_in0(misc), .probe_in1(st_a), .probe_in2(st_b), .probe_in3(hz_tx),
        .probe_in4(hz_rx_a), .probe_in5(r_idle_a), .probe_in6(r_lf_a), .probe_in7(r_rf_a),
        .probe_in8(r_idle_b), .probe_in9(r_lf_b), .probe_in10(r_rf_b),
        .probe_out0(vio_rst), .probe_out1(vio_bitrev), .probe_out2(vio_rxpol), .probe_out3(vio_txpol)
    );
endmodule

// MMCM making a phase-aligned USRCLK / USRCLK2 pair (USRCLK2 = USRCLK / 2).
module usrclk_mmcm #(
    parameter real    CLKIN_PERIOD = 6.4,
    parameter real    MULT = 33.0,
    parameter integer DIV  = 4
) (
    input  wire clkin, input wire rst,
    output wire usrclk, output wire usrclk2, output wire usrclk2_raw, output wire locked
);
    wire fb, c0, c1;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(CLKIN_PERIOD), .CLKFBOUT_MULT_F(MULT), .DIVCLK_DIVIDE(DIV),
        .CLKOUT0_DIVIDE_F(4.0), .CLKOUT1_DIVIDE(8)
    ) u_mmcm (
        .CLKIN1(clkin), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKFBOUTB(),
        .CLKOUT0(c0), .CLKOUT0B(), .CLKOUT1(c1), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(rst)
    );
    BUFG u_b0 (.I(c0), .O(usrclk));
    BUFG u_b1 (.I(c1), .O(usrclk2));
    assign usrclk2_raw = c1;
endmodule

// Async assert, sync deassert.
module rst_sync (input wire clk, input wire arst, output wire rst);
    (* ASYNC_REG = "TRUE" *) reg [2:0] r = 3'b111;
    always @(posedge clk or posedge arst)
        if (arst) r <= 3'b111; else r <= {r[1:0], 1'b0};
    assign rst = r[2];
endmodule

// Counts ev pulses in cclk; every sclk tick reports the delta since the last tick.
module rate_meter (
    input  wire        cclk, input wire ev,
    input  wire        sclk, input wire tick,
    output reg  [31:0] rate = 0
);
    reg [31:0] cnt = 0, gray = 0;
    always @(posedge cclk) begin
        cnt  <= cnt + ev;
        gray <= cnt ^ (cnt >> 1);
    end
    (* ASYNC_REG = "TRUE" *) reg [31:0] g1 = 0, g2 = 0;
    reg [31:0] bin, last = 0;
    integer i;
    always @(*) begin
        bin[31] = g2[31];
        for (i = 30; i >= 0; i = i - 1) bin[i] = bin[i+1] ^ g2[i];
    end
    always @(posedge sclk) begin
        g1 <= gray; g2 <= g1;
        if (tick) begin rate <= bin - last; last <= bin; end
    end
endmodule
`default_nettype wire
