// 10GBASE-R PCS bring-up on both SFP+ cages of the xc7k325t board.
// Uses the Xilinx ten_gig_eth_pcs_pma core: pcs_shared owns the QPLL (SFP A),
// pcs_noshared reuses it (SFP B). Both transmit XGMII idle continuously.
//
// LEDs: 0 heartbeat (100 MHz sys clk)   1 QPLL lock
//       2 GT reset done (A and B)       3 SFP A PCS block lock
//       4 SFP B PCS block lock          5 heartbeat from the 156.25 MHz core clock
// JTAG: status_vio (see read_status.tcl).
module top (
    input  wire       clk,            // 100 MHz
    output wire [5:0] led,
    input  wire       sfp_refclk_p, sfp_refclk_n,
    input  wire       sfp_a_rx_p, sfp_a_rx_n,
    output wire       sfp_a_tx_p, sfp_a_tx_n,
    output wire       sfp_a_tx_disable,
    input  wire       sfp_b_rx_p, sfp_b_rx_n,
    output wire       sfp_b_tx_p, sfp_b_tx_n,
    output wire       sfp_b_tx_disable
);
    // ---------------- power-on reset (~10 ms) + VIO soft reset ----------------
    reg [19:0] por_cnt = 0;
    reg        por     = 1'b1;
    wire       vio_rst;
    always @(posedge clk) begin
        if (por_cnt != 20'hFFFFF) por_cnt <= por_cnt + 1'b1;
        por <= (por_cnt != 20'hFFFFF);
    end
    wire reset = por | vio_rst;

    assign sfp_a_tx_disable = 1'b0;
    assign sfp_b_tx_disable = 1'b0;

    localparam [63:0] IDLE_D = 64'h0707070707070707;
    localparam [7:0]  IDLE_C = 8'hFF;

    wire        coreclk, txusrclk, txusrclk2, areset_core, gttxreset, gtrxreset,
                txuserrdy, rst_cnt_done, qplllock, qplloutclk, qplloutrefclk, resetdone_a;
    wire [63:0] rxd_a, rxd_b;
    wire [7:0]  rxc_a, rxc_b, cs_a, cs_b;
    wire        txrd_b, rxrd_b;

    wire        drpreq_a, drpden_a, drpdwe_a, drpdrdy_a;
    wire [15:0] drpaddr_a, drpdi_a, drpdo_a;
    wire        drpreq_b, drpden_b, drpdwe_b, drpdrdy_b;
    wire [15:0] drpaddr_b, drpdi_b, drpdo_b;

    pcs_shared u_a (
        .refclk_p(sfp_refclk_p), .refclk_n(sfp_refclk_n),
        .reset(reset), .resetdone_out(resetdone_a),
        .coreclk_out(coreclk), .rxrecclk_out(), .dclk(clk),
        .txp(sfp_a_tx_p), .txn(sfp_a_tx_n), .rxp(sfp_a_rx_p), .rxn(sfp_a_rx_n),
        .sim_speedup_control(1'b0),
        .txusrclk_out(txusrclk), .txusrclk2_out(txusrclk2),
        .areset_datapathclk_out(areset_core),
        .gttxreset_out(gttxreset), .gtrxreset_out(gtrxreset), .txuserrdy_out(txuserrdy),
        .reset_counter_done_out(rst_cnt_done),
        .qplllock_out(qplllock), .qplloutclk_out(qplloutclk), .qplloutrefclk_out(qplloutrefclk),
        .xgmii_txd(IDLE_D), .xgmii_txc(IDLE_C), .xgmii_rxd(rxd_a), .xgmii_rxc(rxc_a),
        .configuration_vector(536'd0), .status_vector(), .core_status(cs_a),
        .signal_detect(1'b1), .tx_fault(1'b0),
        .drp_req(drpreq_a), .drp_gnt(drpreq_a),
        .drp_den_o(drpden_a), .drp_dwe_o(drpdwe_a), .drp_daddr_o(drpaddr_a),
        .drp_di_o(drpdi_a), .drp_drdy_o(drpdrdy_a), .drp_drpdo_o(drpdo_a),
        .drp_den_i(drpden_a), .drp_dwe_i(drpdwe_a), .drp_daddr_i(drpaddr_a),
        .drp_di_i(drpdi_a), .drp_drdy_i(drpdrdy_a), .drp_drpdo_i(drpdo_a),
        .tx_disable(), .pma_pmd_type(3'b101)
    );

    pcs_noshared u_b (
        .rxrecclk_out(), .coreclk(coreclk), .dclk(clk),
        .txusrclk(txusrclk), .txusrclk2(txusrclk2), .areset(reset), .txoutclk(),
        .areset_coreclk(areset_core), .gttxreset(gttxreset), .gtrxreset(gtrxreset),
        .txuserrdy(txuserrdy), .qplllock(qplllock), .qplloutclk(qplloutclk),
        .qplloutrefclk(qplloutrefclk), .reset_counter_done(rst_cnt_done),
        .txp(sfp_b_tx_p), .txn(sfp_b_tx_n), .rxp(sfp_b_rx_p), .rxn(sfp_b_rx_n),
        .sim_speedup_control(1'b0),
        .xgmii_txd(IDLE_D), .xgmii_txc(IDLE_C), .xgmii_rxd(rxd_b), .xgmii_rxc(rxc_b),
        .configuration_vector(536'd0), .status_vector(), .core_status(cs_b),
        .tx_resetdone(txrd_b), .rx_resetdone(rxrd_b),
        .signal_detect(1'b1), .tx_fault(1'b0),
        .drp_req(drpreq_b), .drp_gnt(drpreq_b),
        .drp_den_o(drpden_b), .drp_dwe_o(drpdwe_b), .drp_daddr_o(drpaddr_b),
        .drp_di_o(drpdi_b), .drp_drdy_o(drpdrdy_b), .drp_drpdo_o(drpdo_b),
        .drp_den_i(drpden_b), .drp_dwe_i(drpdwe_b), .drp_daddr_i(drpaddr_b),
        .drp_di_i(drpdi_b), .drp_drdy_i(drpdrdy_b), .drp_drpdo_i(drpdo_b),
        .tx_disable(), .pma_pmd_type(3'b101)
    );

    // ---------------- RX classification in coreclk domain ----------------
    // idle: all-idle XGMII word. lf/rf: local/remote fault ordered set in lane 0 or 4.
    function is_lf; input [63:0] d; input [7:0] c;
        is_lf = (c[0] && d[7:0]==8'h9C && d[31:8]==24'h010000) || (c[4] && d[39:32]==8'h9C && d[63:40]==24'h010000);
    endfunction
    function is_rf; input [63:0] d; input [7:0] c;
        is_rf = (c[0] && d[7:0]==8'h9C && d[31:8]==24'h020000) || (c[4] && d[39:32]==8'h9C && d[63:40]==24'h020000);
    endfunction

    reg ev_idle_a, ev_lf_a, ev_rf_a, ev_idle_b, ev_lf_b, ev_rf_b;
    always @(posedge coreclk) begin
        ev_idle_a <= (rxc_a == IDLE_C) && (rxd_a == IDLE_D);
        ev_lf_a   <= is_lf(rxd_a, rxc_a);
        ev_rf_a   <= is_rf(rxd_a, rxc_a);
        ev_idle_b <= (rxc_b == IDLE_C) && (rxd_b == IDLE_D);
        ev_lf_b   <= is_lf(rxd_b, rxc_b);
        ev_rf_b   <= is_rf(rxd_b, rxc_b);
    end

    // ---------------- per-second rates (counted in coreclk, read in clk) ----
    reg [26:0] sec_cnt = 0;
    reg        sec_tick = 0;
    always @(posedge clk) begin
        sec_tick <= (sec_cnt == 27'd99_999_999);
        sec_cnt  <= (sec_cnt == 27'd99_999_999) ? 27'd0 : sec_cnt + 1'b1;
    end

    wire [31:0] hz_core, r_idle_a, r_lf_a, r_rf_a, r_idle_b, r_lf_b, r_rf_b;
    rate_meter m0 (.cclk(coreclk), .ev(1'b1),      .sclk(clk), .tick(sec_tick), .rate(hz_core));
    rate_meter m1 (.cclk(coreclk), .ev(ev_idle_a), .sclk(clk), .tick(sec_tick), .rate(r_idle_a));
    rate_meter m2 (.cclk(coreclk), .ev(ev_lf_a),   .sclk(clk), .tick(sec_tick), .rate(r_lf_a));
    rate_meter m3 (.cclk(coreclk), .ev(ev_rf_a),   .sclk(clk), .tick(sec_tick), .rate(r_rf_a));
    rate_meter m4 (.cclk(coreclk), .ev(ev_idle_b), .sclk(clk), .tick(sec_tick), .rate(r_idle_b));
    rate_meter m5 (.cclk(coreclk), .ev(ev_lf_b),   .sclk(clk), .tick(sec_tick), .rate(r_lf_b));
    rate_meter m6 (.cclk(coreclk), .ev(ev_rf_b),   .sclk(clk), .tick(sec_tick), .rate(r_rf_b));

    // ---------------- status sync to clk ----------------
    (* ASYNC_REG = "TRUE" *) reg [23:0] st_s1, st_s2;
    always @(posedge clk) begin
        st_s1 <= {cs_b, cs_a, 2'b00, rxrd_b, txrd_b, reset, resetdone_a, qplllock, 1'b0};
        st_s2 <= st_s1;
    end
    wire [7:0] misc   = st_s2[7:0];   // [1]qplllock [2]resetdone_a [3]reset [4]txrd_b [5]rxrd_b
    wire [7:0] cs_a_s = st_s2[15:8];  // [0] = PCS block lock
    wire [7:0] cs_b_s = st_s2[23:16];

    // ---------------- LEDs ----------------
    reg [25:0] hb = 0;
    always @(posedge clk) hb <= hb + 1'b1;
    reg [26:0] hb_core = 0;
    always @(posedge coreclk) hb_core <= hb_core + 1'b1;

    assign led[0] = hb[25];
    assign led[1] = misc[1];
    assign led[2] = misc[2] & misc[4] & misc[5];
    assign led[3] = cs_a_s[0];
    assign led[4] = cs_b_s[0];
    assign led[5] = hb_core[26];

    status_vio u_vio (
        .clk(clk),
        .probe_in0(misc), .probe_in1(cs_a_s), .probe_in2(cs_b_s), .probe_in3(hz_core),
        .probe_in4(r_idle_a), .probe_in5(r_lf_a), .probe_in6(r_rf_a),
        .probe_in7(r_idle_b), .probe_in8(r_lf_b), .probe_in9(r_rf_b),
        .probe_out0(vio_rst)
    );
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
