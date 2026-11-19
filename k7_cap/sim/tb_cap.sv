// Testbench for cap_top: XGMII frames (lane 0 / lane 4 starts, good and bad FCS) and the
// internal generator -> capture -> DMA TLPs into a memory model -> host-style consumer
// that parses the ring and checks every record against the frames that were sent,
// including the per-record drop counts. Run: sim/run_sim.sh
`timescale 1ns/1ps
module tb_cap;
  reg clk = 0, rx_clk = 0, ts_clk = 0;
  always #2.0   clk = ~clk;        // 250 MHz
  always #3.2   rx_clk = ~rx_clk;  // 156.25 MHz
  always #3.201 ts_clk = ~ts_clk;
  reg rst = 1, rx_rst = 1;

  reg  [63:0] xgmii_rxd = {8{8'h07}};
  reg  [7:0]  xgmii_rxc = 8'hFF;
  reg         req = 0, we = 0;
  reg  [11:2] addr = 0;
  reg  [31:0] wdata = 0;
  wire [31:0] rdata;
  wire [63:0] tx_tdata;  wire [7:0] tx_tkeep;  wire tx_tlast, tx_tvalid;
  reg         tx_tready = 0;

  cap_top dut (
    .clk(clk), .rst(rst), .rx_clk(rx_clk), .rx_rst(rx_rst),
    .xgmii_rxd(xgmii_rxd), .xgmii_rxc(xgmii_rxc), .ts_clk(ts_clk), .sfp_a_lock(1'b1),
    .req(req), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .requester_id(16'h0200), .bus_master_en(1'b1), .cfg_mps(3'd0),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid),
    .tx_tready(tx_tready)
  );

  // ---------------- register access ----------------
  task automatic wr(input [11:0] a, input [31:0] v);
    @(posedge clk); req <= 1; we <= 1; addr <= a[11:2]; wdata <= v;
    @(posedge clk); req <= 0; we <= 0;
  endtask
  task automatic rd(input [11:0] a, output [31:0] v);
    @(posedge clk); req <= 1; we <= 0; addr <= a[11:2];
    @(posedge clk); req <= 0;
    @(negedge clk); v = rdata;
  endtask
  task automatic rd64(input [11:0] a, output [63:0] v);
    reg [31:0] lo, hi;
    rd(a, lo); rd(a + 4, hi); v = {hi, lo};
  endtask

  // ---------------- memory model fed by the TLP stream ----------------
  byte unsigned mem [longint unsigned];
  int errors = 0;
  longint unsigned tlps = 0;
  int ready_pct = 90;
  always @(posedge clk) tx_tready <= ($urandom % 100) < ready_pct;

  reg [31:0] h0, h1;
  int beat = 0;
  longint unsigned taddr, waddr;
  int dws_left, len_dw;
  bit four;
  task automatic put_dw(input [31:0] d);
    if (dws_left <= 0) begin $display("ERROR: TLP payload longer than length"); errors++; end
    mem[waddr] = d[31:24]; mem[waddr+1] = d[23:16]; mem[waddr+2] = d[15:8]; mem[waddr+3] = d[7:0];
    waddr += 4; dws_left--;
  endtask
  always @(posedge clk) if (tx_tvalid && tx_tready) begin
    if (beat == 0) begin
      h0 = tx_tdata[31:0]; h1 = tx_tdata[63:32];
      four = h0[29];
      len_dw = h0[9:0];
      dws_left = len_dw;
      if (h0[31:30] != 2'b01 || h0[28:24] != 0) begin $display("ERROR: not MWr %h", h0); errors++; end
      if (h1[7:0] != 8'hFF || h1[31:16] != 16'h0200) begin $display("ERROR: DW1 %h", h1); errors++; end
      if (len_dw > 32 || len_dw == 0) begin $display("ERROR: length %0d > MPS", len_dw); errors++; end
    end else if (beat == 1) begin
      if (four) begin
        taddr = {tx_tdata[31:0], tx_tdata[63:32]};
        if (taddr[63:32] == 0) begin $display("ERROR: 4DW header below 4 GB"); errors++; end
      end else begin
        taddr = tx_tdata[31:0];
      end
      waddr = taddr;
      if ((taddr & 12'hFFF) + len_dw * 4 > 4096) begin $display("ERROR: TLP crosses 4 KB"); errors++; end
      if (!four) put_dw(tx_tdata[63:32]);
    end else begin
      put_dw(tx_tdata[31:0]);
      if (tx_tkeep[4]) put_dw(tx_tdata[63:32]);
    end
    beat++;
    if (tx_tlast) begin
      if (dws_left != 0) begin $display("ERROR: TLP payload short by %0d DW", dws_left); errors++; end
      beat = 0; tlps++;
    end
  end

  // ---------------- XGMII frame source ----------------
  typedef struct { byte unsigned b[$]; bit bad; longint unsigned seq; } frame_t;
  frame_t sent[$];
  byte unsigned lane_d[$];  bit lane_c[$];
  int xg_ifg_min = 12;

  function automatic [31:0] crc32(byte unsigned b[$]);
    reg [31:0] c; c = 32'hFFFFFFFF;
    foreach (b[i]) begin
      c ^= b[i];
      repeat (8) c = (c >> 1) ^ (32'hEDB88320 & {32{c[0]}});
    end
    return ~c;
  endfunction

  task automatic push_frame(input int len, input bit bad, input longint unsigned seq);
    frame_t f; reg [31:0] fcs; int ifg; byte unsigned q[$];
    f.bad = bad; f.seq = seq;
    for (int i = 0; i < len; i++) q.push_back($urandom);
    for (int i = 0; i < 6; i++) q[i] = 8'hFF;
    for (int i = 0; i < 8; i++) q[12 + i] = seq >> (8 * i);
    fcs = crc32(q);
    if (bad) fcs ^= 32'h0000_0100;
    // start must be on lane 0 or 4
    while (lane_d.size() % 4 != 0) begin lane_d.push_back(8'h07); lane_c.push_back(1); end
    lane_d.push_back(8'hFB); lane_c.push_back(1);
    repeat (6) begin lane_d.push_back(8'h55); lane_c.push_back(0); end
    lane_d.push_back(8'hD5); lane_c.push_back(0);
    foreach (q[i]) begin lane_d.push_back(q[i]); lane_c.push_back(0); end
    for (int i = 0; i < 4; i++) begin
      lane_d.push_back(fcs >> (8 * i)); lane_c.push_back(0);
      q.push_back(fcs >> (8 * i));    // kept in the record when keep_fcs is on
    end
    lane_d.push_back(8'hFD); lane_c.push_back(1);
    ifg = xg_ifg_min + ($urandom % 8);
    repeat (ifg - 1) begin lane_d.push_back(8'h07); lane_c.push_back(1); end
    f.b = q;
    sent.push_back(f);
  endtask

  always @(posedge rx_clk) begin
    if (lane_d.size() >= 8) begin
      for (int i = 0; i < 8; i++) begin
        xgmii_rxd[8*i +: 8] <= lane_d.pop_front();
        xgmii_rxc[i] <= lane_c.pop_front();
      end
    end else begin
      xgmii_rxd <= {8{8'h07}}; xgmii_rxc <= 8'hFF;
    end
  end

  // ---------------- host consumer ----------------
  longint unsigned blk_base [2] = '{64'h0000_0001_0000_0000, 64'h0000_0000_0020_0000};
  localparam longint unsigned STAT = 64'h3000_0000;
  localparam int BLK_SHIFT = 12, NBLK = 2;
  longint unsigned tail = 0;
  int consume_delay = 0;

  function automatic byte unsigned rb(longint unsigned off);
    longint unsigned a = blk_base[(off >> BLK_SHIFT) % NBLK] + (off & ((1 << BLK_SHIFT) - 1));
    if (!mem.exists(a)) return 8'hEE;
    return mem[a];
  endfunction
  function automatic longint unsigned r64(longint unsigned off);
    longint unsigned v = 0;
    for (int i = 0; i < 8; i++) v |= longint'(rb(off + i)) << (8 * i);
    return v;
  endfunction
  function automatic longint unsigned stat_head();
    longint unsigned v = 0;
    for (int i = 0; i < 8; i++) v |= (mem.exists(STAT + i) ? longint'(mem[STAT + i]) : 0) << (8 * i);
    return v;
  endfunction

  // checking state
  int  exp_idx = 0;           // next frame in sent[] the ring should contain
  bit  chk_keep_bad = 0, chk_keep_fcs = 0, chk_tg = 0;
  int  chk_snap = 9600;
  longint unsigned recs = 0, drops_seen = 0, last_ts = 0;
  longint unsigned tg_next = 0;

  task automatic consume_one(input longint unsigned head, output bit got);
    longint unsigned ts, w1, rlen;
    int clen, wlen, flags, drops, nb;
    got = 0;
    if (head - tail < 16) return;
    ts = r64(tail); w1 = r64(tail + 8);
    clen = w1[15:0]; wlen = w1[31:16]; flags = w1[39:32]; drops = w1[63:48];
    rlen = 16 + ((clen + 7) / 8) * 8;
    if (head - tail < rlen) return;
    got = 1;
    if (ts < last_ts) begin $display("ERROR: timestamp went back"); errors++; end
    last_ts = ts;
    drops_seen += drops;
    if (chk_tg) begin
      longint unsigned seq = r64(tail + 16 + 16);
      if (seq != tg_next + drops) begin
        $display("ERROR: tg seq %0d expected %0d (+%0d drops)", seq, tg_next, drops); errors++;
      end
      tg_next = seq + 1;
      if (wlen != chk_snap && clen != wlen) begin end
    end else begin
      frame_t f;
      // skip frames the ring cannot contain: bad ones (unless kept) and dropped ones
      while (exp_idx < sent.size() && sent[exp_idx].bad && !chk_keep_bad) exp_idx++;
      for (int d = 0; d < drops; d++) begin
        exp_idx++;
        while (exp_idx < sent.size() && sent[exp_idx].bad && !chk_keep_bad) exp_idx++;
      end
      if (exp_idx >= sent.size()) begin $display("ERROR: record with no frame"); errors++; return; end
      f = sent[exp_idx++];
      nb = chk_keep_fcs ? f.b.size() : f.b.size() - 4;
      if (wlen != nb) begin $display("ERROR: rec %0d wire len %0d expected %0d", recs, wlen, nb); errors++; end
      if (clen != (nb > chk_snap ? chk_snap : nb)) begin $display("ERROR: cap len %0d", clen); errors++; end
      if (flags[0] != f.bad || flags[1] != (nb > chk_snap) || flags[2] != chk_keep_fcs) begin
        $display("ERROR: rec %0d flags %h (bad %0d)", recs, flags, f.bad); errors++;
      end
      for (int i = 0; i < clen; i++)
        if (rb(tail + 16 + i) != f.b[i]) begin
          $display("ERROR: rec %0d (seq %0d) byte %0d = %h expected %h", recs, f.seq, i, rb(tail + 16 + i), f.b[i]);
          errors++; break;
        end
    end
    recs++;
    tail += rlen;
  endtask

  task automatic consumer(input longint unsigned until_recs, input int timeout_us);
    bit got; longint unsigned head; time t0 = $time; time tl = $time;
    while (recs < until_recs && $time - t0 < timeout_us * 1000 && $time - tl < 30000) begin
      head = stat_head();
      consume_one(head, got);
      if (got) begin
        tl = $time;
        if (consume_delay) repeat (consume_delay) @(posedge clk);
        wr(12'h12C, tail[31:0]);
      end else @(posedge clk);
    end
  endtask

  task automatic setup(input [31:0] ctrl, input [31:0] snap);
    wr(12'h100, 32'h2);                // reset
    repeat (20) @(posedge clk);
    wr(12'h108, snap);
    wr(12'h10C, (NBLK << 16) | BLK_SHIFT);
    wr(12'h110, 0);
    wr(12'h114, blk_base[0][31:0]); wr(12'h118, blk_base[0][63:32]);
    wr(12'h114, blk_base[1][31:0]); wr(12'h118, blk_base[1][63:32]);
    wr(12'h120, STAT[31:0]); wr(12'h124, STAT[63:32]);
    wr(12'h128, 1024);
    wr(12'h11C, 50);
    wr(12'h12C, 0);
    wr(12'h100, ctrl & ~32'h1);       // release reset, configure
    repeat (20) @(posedge clk);
    tail = 0; recs = 0; drops_seen = 0; last_ts = 0;
    for (longint unsigned a = STAT; a < STAT + 8; a++) mem.delete(a);
    wr(12'h100, ctrl | 32'h1);        // enable
  endtask

  task automatic report(input string name);
    reg [63:0] rxf, cap, drop, bad, rec, tl, st;
    rd64(12'h150, rxf); rd64(12'h160, cap); rd64(12'h168, drop); rd64(12'h170, bad);
    rd64(12'h178, rec); rd64(12'h180, tl); rd64(12'h188, st);
    $display("%s: rx %0d cap %0d drop %0d bad %0d records %0d tlps %0d (tb %0d) stalls %0d | host recs %0d drops %0d tail %0d errors %0d",
             name, rxf, cap, drop, bad, rec, tl, tlps, st, recs, drops_seen, tail, errors);
  endtask

  initial begin
    reg [31:0] v;
    repeat (10) @(posedge clk);
    rst = 0;
    repeat (10) @(posedge rx_clk);
    rx_rst = 0;
    rd(12'h000, v);

    // ---- 1: XGMII frames, FCS stripped, bad frames discarded, fast host ----
    chk_keep_bad = 0; chk_keep_fcs = 0; chk_tg = 0; chk_snap = 9600;
    setup(32'h0, 9600);
    sent.delete(); exp_idx = 0;
    fork
      begin
        for (int i = 0; i < 300; i++) begin
          int len;
          len = ($urandom % 4 == 0) ? 60 + $urandom % 1455 : 60 + $urandom % 40;
          push_frame(len, ($urandom % 10) == 0, i);
          while (lane_d.size() > 4000) @(posedge rx_clk);
        end
      end
      consumer(271, 400);
    join_any
    repeat (2000) @(posedge clk);
    consumer(1000, 30);
    repeat (40000) @(posedge rx_clk);   // counter snapshot interval
    report("phase 1");
    begin : p1chk
      int good; good = 0; foreach (sent[i]) if (!sent[i].bad) good++;
      if (recs != good || drops_seen != 0) begin $display("ERROR: phase 1 got %0d records, %0d good frames sent", recs, good); errors++; end
    end

    // ---- 2: FCS kept, bad frames kept, snaplen 128, slow host (ring full -> drops) ----
    chk_keep_bad = 1; chk_keep_fcs = 1; chk_snap = 128;
    setup(32'h0C, 128);
    sent.delete(); exp_idx = 0;
    consume_delay = 300;
    ready_pct = 70;
    fork
      begin
        for (int i = 0; i < 4000; i++) begin
          push_frame(60 + $urandom % 200, ($urandom % 8) == 0, i);
          while (lane_d.size() > 4000) @(posedge rx_clk);
        end
      end
      consumer(100000, 1000);
    join_any
    $display("phase 2 slow part ended at %0t, recs %0d drops %0d", $time, recs, drops_seen);
    consume_delay = 0;
    consumer(100000, 2000);
    repeat (40000) @(posedge rx_clk);
    report("phase 2");
    if (recs + drops_seen != sent.size()) begin
      $display("ERROR: phase 2 records %0d + drops %0d != frames %0d (trailing drops are not reported in a record)",
               recs, drops_seen, sent.size());
    end

    // ---- 3: test generator at line rate (60 B, gap 3), fast host ----
    chk_keep_bad = 0; chk_keep_fcs = 0; chk_tg = 1; chk_snap = 9600; tg_next = 0;
    ready_pct = 100;
    wr(12'h140, {16'd3, 16'd60});
    setup(32'h10, 9600);
    consumer(20000, 1500);
    wr(12'h100, 32'h10);          // disable
    consumer(1000000, 20);
    repeat (40000) @(posedge rx_clk);
    report("phase 3");
    if (recs != tg_next) begin $display("ERROR: phase 3 %0d records, generator seq %0d", recs, tg_next); errors++; end
    begin reg [63:0] g, rf, cf; rd64(12'h190, g); rd64(12'h150, rf); rd64(12'h160, cf);
      if (g != rf || cf != recs) begin $display("ERROR: TG_SEQ %0d rx %0d captured %0d records %0d", g, rf, cf, recs); errors++; end end

    if (errors == 0) $display("PASS"); else $display("FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
