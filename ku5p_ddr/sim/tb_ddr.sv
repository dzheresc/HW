// Testbench for the DDR datapath: ddr_ctrl (regs, single access, DMA) + ddr_bridge
// + ddr_memtest, against a behavioral MIG native-interface model and a host
// model on the PCIe requester interfaces (RQ capture, RC completions split at
// 64-byte RCB boundaries and interleaved across tags).
//   xvlog -sv ...; xelab -L xpm tb_ddr; xsim -R
`timescale 1ns/1ps
module tb_ddr;
  localparam AW = 26;
  reg uclk = 0, ui_clk = 0;
  always #2.0  uclk = ~uclk;     // 250 MHz
  always #1.667 ui_clk = ~ui_clk; // 300 MHz
  reg urst = 1, ui_rst = 1;

  // ---------------- register bus ----------------
  reg req = 0, we = 0;  reg [11:2] addr = 0;  reg [31:0] wdata = 0;
  wire [31:0] rdata;
  task wr(input [11:0] a, input [31:0] d);
    begin
      @(posedge uclk); req <= 1; we <= 1; addr <= a[11:2]; wdata <= d;
      @(posedge uclk); req <= 0; we <= 0;
      @(posedge uclk);
    end
  endtask
  task rd(input [11:0] a, output [31:0] d);
    begin
      @(posedge uclk); req <= 1; we <= 0; addr <= a[11:2];
      @(posedge uclk); req <= 0;
      @(posedge uclk); d = rdata;
    end
  endtask

  // ---------------- DUT ----------------
  wire          mt_tog;
  wire [AW-1:0] mt_base;  wire [AW:0] mt_len;  wire mt_wr, mt_rd;  wire [1:0] mt_mode;
  wire [31:0]   mt_seed;  wire mt_busy;
  wire [31:0]   mt_errs, mt_wcyc, mt_rcyc, mt_err_addr, mt_err_exp, mt_err_got;
  wire          c_valid, c_ready, c_we, r_valid, r_pop;
  wire [AW-1:0] c_addr;  wire [255:0] c_wdata, r_data;
  wire [255:0]  rq_tdata;  wire [7:0] rq_tkeep;  wire rq_tlast, rq_tvalid;  wire [61:0] rq_tuser;
  reg           rq_tready = 1;
  reg  [255:0]  rc_tdata = 0;  reg rc_tlast = 0, rc_tvalid = 0;  wire rc_tready;
  reg  [1:0]    mps = 2'd1;  reg [2:0] mrrs = 3'd2;
  wire          calib;
  reg           calib_m = 0;
  wire          ddr_sys_rst;

  ddr_ctrl #(.AW(AW)) dut (
    .clk(uclk), .rst(urst), .req(req), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .calib_raw(calib_m), .ui_rst_raw(ui_rst), .mt_busy_raw(mt_busy),
    .mt_errs(mt_errs), .mt_wcyc(mt_wcyc), .mt_rcyc(mt_rcyc),
    .mt_err_addr(mt_err_addr), .mt_err_exp(mt_err_exp), .mt_err_got(mt_err_got),
    .mt_tog(mt_tog), .xcfg_mt_base(mt_base), .xcfg_mt_len(mt_len), .xcfg_mt_wr(mt_wr),
    .xcfg_mt_rd(mt_rd), .xcfg_mt_mode(mt_mode), .xcfg_mt_seed(mt_seed), .ddr_sys_rst(ddr_sys_rst),
    .max_payload(mps), .max_read_req(mrrs), .bme(1'b1),
    .rq_tdata(rq_tdata), .rq_tkeep(rq_tkeep), .rq_tlast(rq_tlast), .rq_tuser(rq_tuser),
    .rq_tvalid(rq_tvalid), .rq_tready(rq_tready),
    .rc_tdata(rc_tdata), .rc_tlast(rc_tlast), .rc_tvalid(rc_tvalid), .rc_tready(rc_tready),
    .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata),
    .r_valid(r_valid), .r_data(r_data), .r_pop(r_pop),
    .calib_done(calib), .mt_err_led()
  );

  reg [2:0] mtt_s = 0;  reg mtt_q = 0;
  always @(posedge ui_clk) begin mtt_s <= {mtt_s[1:0], mt_tog}; mtt_q <= mtt_s[2]; end
  wire mt_start = mtt_s[2] ^ mtt_q;

  wire br_idle, mt_sel, mt_en, mt_wren;  wire [2:0] mt_cmd;  wire [28:0] mt_addr;  wire [255:0] mt_wdata;
  wire app_en, app_wdf_wren, app_wdf_end;  wire [2:0] app_cmd;  wire [28:0] app_addr;
  wire [255:0] app_wdf_data;  wire [31:0] app_wdf_mask;
  reg  app_rdy = 0, app_wdf_rdy = 0, app_rd_valid = 0;  reg [255:0] app_rd_data = 0;

  ddr_memtest #(.AW(AW)) mt (
    .clk(ui_clk), .rst(ui_rst), .start(mt_start),
    .cfg_base(mt_base), .cfg_len(mt_len), .cfg_wr(mt_wr), .cfg_rd(mt_rd), .cfg_mode(mt_mode),
    .cfg_seed(mt_seed), .br_idle(br_idle),
    .sel(mt_sel), .app_en(mt_en), .app_cmd(mt_cmd), .app_addr(mt_addr), .app_wren(mt_wren),
    .app_wdata(mt_wdata), .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy),
    .rd_valid(app_rd_valid), .rd_data(app_rd_data),
    .busy(mt_busy), .xst_errs(mt_errs), .xst_wcyc(mt_wcyc), .xst_rcyc(mt_rcyc),
    .xst_err_addr(mt_err_addr), .xst_err_exp(mt_err_exp), .xst_err_got(mt_err_got)
  );

  ddr_bridge #(.AW(AW)) br (
    .uclk(uclk), .urst(urst), .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr),
    .c_wdata(c_wdata), .r_valid(r_valid), .r_data(r_data), .r_pop(r_pop),
    .ui_clk(ui_clk), .ui_rst(ui_rst), .br_idle(br_idle),
    .mt_sel(mt_sel), .mt_en(mt_en), .mt_cmd(mt_cmd), .mt_addr(mt_addr), .mt_wren(mt_wren),
    .mt_wdata(mt_wdata),
    .app_en(app_en), .app_cmd(app_cmd), .app_addr(app_addr), .app_wdf_wren(app_wdf_wren),
    .app_wdf_end(app_wdf_end), .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask),
    .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy), .app_rd_data_valid(app_rd_valid),
    .app_rd_data(app_rd_data)
  );

  // ---------------- MIG model ----------------
  reg [255:0] ddr [longint];
  function [255:0] ddr_get(input longint w);
    ddr_get = ddr.exists(w) ? ddr[w] : {8{32'hDEAD_BEEF}};
  endfunction
  typedef struct { longint t; longint w; } rdq_t;
  rdq_t rq [$];
  longint cyc = 0;
  integer bad_proto = 0;
  always @(posedge ui_clk) begin
    cyc <= cyc + 1;
    app_rdy <= !ui_rst && ($urandom % 8 != 0);
    app_wdf_rdy <= !ui_rst && ($urandom % 8 != 0);
    if (app_en && app_rdy) begin
      if (app_addr[2:0] != 0) bad_proto = bad_proto + 1;
      if (app_cmd == 3'd0) begin
        if (!(app_wdf_wren && app_wdf_rdy && app_wdf_end)) bad_proto = bad_proto + 1;
        ddr[app_addr >> 3] = app_wdf_data;
      end else
        rq.push_back('{cyc + 20 + ($urandom % 20), app_addr >> 3});
    end else if (app_wdf_wren) bad_proto = bad_proto + 1;
    app_rd_valid <= 0;
    if (rq.size() > 0 && rq[0].t <= cyc) begin
      rdq_t e;
      e = rq.pop_front();
      app_rd_valid <= 1;
      app_rd_data <= ddr_get(e.w);
    end
  end

  // ---------------- host model ----------------
  reg [31:0] hmem [longint];    // dword index
  function [31:0] h_get(input longint a);
    h_get = hmem.exists(a) ? hmem[a] : 32'hBAAD_F00D;
  endfunction

  // RQ capture
  integer rq_beat = 0;  longint w_addr;  integer w_dw;  integer n_mwr = 0, n_mrd = 0;
  integer max_mwr = 0;
  typedef struct { longint addr; integer bytes; integer tag; } mrd_t;
  mrd_t mrds [$];
  always @(posedge uclk) begin
    rq_tready <= ($urandom % 5 != 0);
    if (rq_tvalid && rq_tready) begin
      if (rq_beat == 0) begin
        integer t;  integer dwc;
        t = rq_tdata[78:75];
        dwc = rq_tdata[74:64];
        if (rq_tuser[7:0] != 8'hFF) bad_proto = bad_proto + 1;
        if (t == 0) begin
          if (!rq_tlast || rq_tkeep != 8'h0F) bad_proto = bad_proto + 1;
          mrds.push_back('{ {rq_tdata[63:2], 2'b00}, dwc * 4, rq_tdata[103:96] });
          n_mrd = n_mrd + 1;
        end else if (t == 1) begin
          w_addr = {rq_tdata[63:2], 2'b00} >> 2;
          w_dw = dwc;
          if (dwc * 4 > max_mwr) max_mwr = dwc * 4;
          for (int i = 4; i < 8; i++) begin hmem[w_addr] = rq_tdata[32*i +: 32]; w_addr++; w_dw--; end
          n_mwr = n_mwr + 1;
        end else bad_proto = bad_proto + 1;
      end else begin
        for (int i = 0; i < 8; i++)
          if (rq_tkeep[i]) begin
            if (w_dw <= 0) bad_proto = bad_proto + 1;
            hmem[w_addr] = rq_tdata[32*i +: 32]; w_addr++; w_dw--;
          end
      end
      rq_beat = rq_tlast ? 0 : rq_beat + 1;
      if (rq_tlast && rq_beat == 0 && w_dw != 0 && rq_tdata[78:75] != 0) ;
    end
  end

  // RC generator: completions split at 64-byte boundaries; picks a random
  // outstanding request each time (interleaving tags).
  typedef struct { longint addr; integer bc; integer tag; integer reqb; } cpl_t;
  cpl_t act [$];
  reg [31:0] q [$];   // dwords of the TLP being sent
  integer q_last;
  initial begin
    forever begin
      @(posedge uclk);
      while (mrds.size() > 0) begin
        mrd_t m;
        m = mrds.pop_front();
        act.push_back('{m.addr, m.bytes, m.tag, m.bytes});
      end
      if (act.size() > 0 && $urandom % 3 == 0) begin
        integer k, n, rem;
        cpl_t c;
        k = $urandom % act.size();
        c = act[k];
        n = 64 - (c.addr % 64);
        if ($urandom % 2) n = n + 64;          // sometimes 128-byte completions
        if (n > c.bc) n = c.bc;
        // descriptor DW0..2
        q.delete();
        q.push_back({1'b0, (c.bc == n) ? 1'b1 : 1'b0, 1'b0, c.bc[12:0], 4'd0, c.addr[11:0]});
        q.push_back({16'h0000, 2'b00, 3'b000, n[12:2] & 11'h7FF});
        q.push_back({8'd0, 16'h0000, c.tag[7:0]});
        for (int i = 0; i < n / 4; i++) q.push_back(h_get((c.addr >> 2) + i));
        if (c.bc == n) act.delete(k);
        else begin act[k].addr = c.addr + n; act[k].bc = c.bc - n; end
        // send
        while (q.size() > 0) begin
          rc_tvalid <= 1;
          for (int i = 0; i < 8; i++) rc_tdata[32*i +: 32] <= (i < q.size()) ? q[i] : 32'h0;
          rc_tlast <= (q.size() <= 8);
          for (int i = 0; i < 8 && q.size() > 0; i++) void'(q.pop_front());
          do @(posedge uclk); while (!rc_tready);
          rc_tvalid <= 0;
          rc_tlast <= 0;
        end
      end
    end
  end

  // ---------------- tests ----------------
  integer fails = 0;
  reg [31:0] v;
  task check(input [255:0] got, input [255:0] exp, input [8*32-1:0] what);
    if (got !== exp) begin fails = fails + 1; $display("FAIL %0s: got %h exp %h", what, got, exp); end
  endtask
  task wait_mt;
    begin
      rd(12'hC00, v);
      while (!v[3]) rd(12'hC00, v);
    end
  endtask
  task dma(input [63:0] host, input [31:0] daddr, input [31:0] len, input dir);
    begin
      wr(12'hC40, host[31:0]); wr(12'hC44, host[63:32]); wr(12'hC48, daddr); wr(12'hC4C, len);
      wr(12'hC50, {30'd0, dir, 1'b1});
      rd(12'hC54, v);
      while (v[0] || !v[1]) rd(12'hC54, v);
      if (v[2]) begin fails = fails + 1; $display("FAIL dma error %h", v); end
      rd(12'hC58, v);
      $display("dma dir %0d len %0d: %0d cycles", dir, len, v);
    end
  endtask

  integer i, j;
  reg [255:0] w;
  initial begin
    repeat (20) @(posedge uclk);
    urst <= 0;
    repeat (10) @(posedge ui_clk);
    ui_rst <= 0;
    calib_m <= 1;
    repeat (200) @(posedge uclk);

    // single access
    for (j = 0; j < 8; j++) wr(12'hCA0 + 4 * j, 32'h1111_0000 + j);
    wr(12'hC80, 32'h0000_1000);
    wr(12'hC84, 32'h2);
    rd(12'hC84, v); while (v[0]) rd(12'hC84, v);
    repeat (50) @(posedge uclk);
    check(ddr_get(32'h1000 >> 5), {32'h11110007, 32'h11110006, 32'h11110005, 32'h11110004,
                                    32'h11110003, 32'h11110002, 32'h11110001, 32'h11110000}, "sa write");
    ddr[(32'h2000 >> 5)] = {8{32'hA5A5_0000}} ^ {32'd7, 32'd6, 32'd5, 32'd4, 32'd3, 32'd2, 32'd1, 32'd0};
    wr(12'hC80, 32'h0000_2000);
    wr(12'hC84, 32'h1);
    rd(12'hC84, v); while (v[0]) rd(12'hC84, v);
    for (j = 0; j < 8; j++) begin rd(12'hCA0 + 4 * j, v); check(v, 32'hA5A5_0000 ^ j, "sa read"); end

    // memtest, all modes, 16 KB at 0x10000
    for (i = 0; i < 4; i++) begin
      wr(12'hC14, 32'h0001_0000); wr(12'hC18, 32'h4000); wr(12'hC1C, 32'h1234_5678 + i);
      wr(12'hC10, 32'h7 | (i << 4));
      wait_mt;
      rd(12'hC20, v); check(v, 0, "memtest errs");
      rd(12'hC24, v); $display("memtest mode %0d: write %0d cycles", i, v);
      rd(12'hC28, v); $display("memtest mode %0d: read  %0d cycles", i, v);
      rd(12'hC2C, v); check(v, 32'hFFFF_FFFF, "memtest no err addr");
    end
    // check a pattern word directly: mode 3 (last), seed 0x1234567B, word 0x10000/32 even -> seed
    check(ddr_get(32'h10000 >> 5), {8{32'h1234_567B}}, "memtest mode3 data");
    // inject an error, read-only pass
    w = ddr[(32'h10000 + 32'h120) >> 5];
    w[32*3 +: 32] = w[32*3 +: 32] ^ 32'h0000_0100;
    ddr[(32'h10000 + 32'h120) >> 5] = w;
    wr(12'hC10, 32'h5 | (3 << 4));
    wait_mt;
    rd(12'hC20, v); check(v, 1, "memtest injected errs");
    rd(12'hC2C, v); check(v, 32'h1012C, "memtest err addr");
    rd(12'hC30, v); check(v, {224'd0, ~32'h1234_567B}, "memtest err exp");
    rd(12'hC34, v); check(v, {224'd0, ~32'h1234_567B ^ 32'h100}, "memtest err got");

    // DMA host -> DDR, then DDR -> host, for MRRS/MPS combinations
    for (i = 0; i < 3; i++) begin
      mrrs = (i == 0) ? 3'd2 : (i == 1) ? 3'd0 : 3'd5;   // 512, 128, 4096 (capped at 512)
      mps  = (i == 0) ? 2'd1 : (i == 1) ? 2'd0 : 2'd2;   // 256, 128, 512 (capped at 256)
      for (j = 0; j < 8192 / 4; j++) hmem[(64'h1_0000_0000 + 32'h10000) / 4 + j] = $urandom;
      dma(64'h1_0001_0000, 32'h0004_0020, 8192, 0);
      repeat (100) @(posedge uclk);   // last writes may still be in the bridge FIFO
      for (j = 0; j < 8192 / 32; j++) begin
        w = ddr_get((32'h0004_0020 >> 5) + j);
        for (int k = 0; k < 8; k++)
          if (w[32*k +: 32] !== h_get((64'h1_0001_0000 >> 2) + 8 * j + k)) begin
            fails++; if (fails < 10) $display("FAIL h2c word %0d.%0d", j, k);
          end
      end
      dma(64'h0000_0000_0008_0000, 32'h0004_0020, 8192, 1);
      for (j = 0; j < 8192 / 4; j++)
        if (h_get((32'h8_0000 >> 2) + j) !== h_get((64'h1_0001_0000 >> 2) + j)) begin
          fails++; if (fails < 10) $display("FAIL c2h dw %0d", j);
        end
      $display("pass %0d: MRd %0d, MWr %0d, max MWr %0d bytes", i, n_mrd, n_mwr, max_mwr);
      for (j = 0; j < 8192 / 4; j++) hmem.delete((32'h8_0000 >> 2) + j);
    end
    // bad arguments
    wr(12'hC4C, 32'd100); wr(12'hC50, 32'h1);
    rd(12'hC54, v); if (v[6:4] != 3'd4) begin fails++; $display("FAIL bad-arg error code %h", v); end

    if (bad_proto) begin fails++; $display("FAIL protocol violations: %0d", bad_proto); end
    $display("%s (%0d failures)", fails ? "TEST FAILED" : "TEST PASSED", fails);
    $finish;
  end
  initial begin #20ms; $display("TEST FAILED (timeout)"); $finish; end
endmodule
