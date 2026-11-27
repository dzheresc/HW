// Testbench for cap_top (k7_cap_ab): two XGMII sources on slightly different clocks (lane 0 /
// lane 4 starts, good and bad FCS) and the two internal generators -> per-port capture ->
// record merge -> DMA TLPs into a memory model -> host-style consumer that parses the ring
// and checks every record against the frames sent on its port (byte 13 of the record),
// including the per-port drop counts. Run: sim/run_sim.sh
`timescale 1ns/1ps
module tb_cap;
  reg clk = 0, rx_clk_a = 0, rx_clk_b = 0, ts_clk = 0;
  always #2.0    clk = ~clk;            // 250 MHz
  always #3.2    rx_clk_a = ~rx_clk_a;  // 156.25 MHz
  always #3.2003 rx_clk_b = ~rx_clk_b;  // 94 ppm slower
  always #3.201  ts_clk = ~ts_clk;
  reg rst = 1, rx_rst = 1;

  reg  [63:0] xgd_a = {8{8'h07}}, xgd_b = {8{8'h07}};
  reg  [7:0]  xgc_a = 8'hFF,      xgc_b = 8'hFF;
  reg         req = 0, we = 0;
  reg  [11:2] addr = 0;
  reg  [31:0] wdata = 0;
  wire [31:0] rdata;
  wire [63:0] tx_tdata;  wire [7:0] tx_tkeep;  wire tx_tlast, tx_tvalid;
  reg         tx_tready = 0;

  cap_top dut (
    .clk(clk), .rst(rst),
    .rx_clk_a(rx_clk_a), .rx_rst_a(rx_rst), .xgmii_rxd_a(xgd_a), .xgmii_rxc_a(xgc_a),
    .rx_clk_b(rx_clk_b), .rx_rst_b(rx_rst), .xgmii_rxd_b(xgd_b), .xgmii_rxc_b(xgc_b),
    .ts_clk(ts_clk), .sfp_a_lock(1'b1), .sfp_b_lock(1'b1),
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

  // ---------------- XGMII frame sources, one per port ----------------
  typedef struct { byte unsigned b[$]; bit bad; longint unsigned seq; } frame_t;
  frame_t sent_a[$], sent_b[$];
  byte unsigned ld_a[$], ld_b[$];
  bit lc_a[$], lc_b[$];
  int xg_ifg_min = 12;

  function automatic [31:0] crc32(byte unsigned b[$]);
    reg [31:0] c; c = 32'hFFFFFFFF;
    foreach (b[i]) begin
      c ^= b[i];
      repeat (8) c = (c >> 1) ^ (32'hEDB88320 & {32{c[0]}});
    end
    return ~c;
  endfunction

  task automatic lane_push(input int p, input byte unsigned d, input bit c);
    if (p == 0) begin ld_a.push_back(d); lc_a.push_back(c); end
    else        begin ld_b.push_back(d); lc_b.push_back(c); end
  endtask
  function automatic int lane_size(input int p);
    return (p == 0) ? ld_a.size() : ld_b.size();
  endfunction
  function automatic int sent_size(input int p);
    return (p == 0) ? sent_a.size() : sent_b.size();
  endfunction
  function automatic bit sent_bad(input int p, input int i);
    return (p == 0) ? sent_a[i].bad : sent_b[i].bad;
  endfunction

  task automatic push_frame(input int p, input int len, input bit bad, input longint unsigned seq);
    frame_t f; reg [31:0] fcs; int ifg; byte unsigned q[$];
    f.bad = bad; f.seq = seq;
    for (int i = 0; i < len; i++) q.push_back($urandom);
    for (int i = 0; i < 6; i++) q[i] = 8'hFF;
    for (int i = 0; i < 8; i++) q[12 + i] = seq >> (8 * i);
    q[20] = p;                       // port in the payload too
    fcs = crc32(q);
    if (bad) fcs ^= 32'h0000_0100;
    // start must be on lane 0 or 4
    while (lane_size(p) % 4 != 0) lane_push(p, 8'h07, 1);
    lane_push(p, 8'hFB, 1);
    repeat (6) lane_push(p, 8'h55, 0);
    lane_push(p, 8'hD5, 0);
    foreach (q[i]) lane_push(p, q[i], 0);
    for (int i = 0; i < 4; i++) begin
      lane_push(p, fcs >> (8 * i), 0);
      q.push_back(fcs >> (8 * i));    // kept in the record when keep_fcs is on
    end
    lane_push(p, 8'hFD, 1);
    ifg = xg_ifg_min + ($urandom % 8);
    repeat (ifg - 1) lane_push(p, 8'h07, 1);
    f.b = q;
    if (p == 0) sent_a.push_back(f); else sent_b.push_back(f);
  endtask

  always @(posedge rx_clk_a) begin
    if (ld_a.size() >= 8) begin
      for (int i = 0; i < 8; i++) begin xgd_a[8*i +: 8] <= ld_a.pop_front(); xgc_a[i] <= lc_a.pop_front(); end
    end else begin
      xgd_a <= {8{8'h07}}; xgc_a <= 8'hFF;
    end
  end
  always @(posedge rx_clk_b) begin
    if (ld_b.size() >= 8) begin
      for (int i = 0; i < 8; i++) begin xgd_b[8*i +: 8] <= ld_b.pop_front(); xgc_b[i] <= lc_b.pop_front(); end
    end else begin
      xgd_b <= {8{8'h07}}; xgc_b <= 8'hFF;
    end
  end

  task automatic send_frames(input int p, input int n, input int lmin, input int lspread, input int bad_1_in);
    for (int i = 0; i < n; i++) begin
      int len;
      len = (lspread > 1000 && $urandom % 4 != 0) ? lmin + $urandom % 40 : lmin + $urandom % lspread;
      push_frame(p, len, ($urandom % bad_1_in) == 0, i);
      while (lane_size(p) > 4000) @(posedge rx_clk_a);
    end
  endtask

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

  // checking state, per port where it matters
  bit  chk_keep_bad = 0, chk_keep_fcs = 0, chk_tg = 0;
  bit  chk_port_ok [2] = '{1, 1};          // records allowed from this port
  int  chk_snap = 9600;
  int  exp_idx [2];                        // next frame in sent_x[] the ring should contain
  longint unsigned recs = 0;
  longint unsigned recs_p [2], drops_p [2], last_ts [2], tg_next [2];

  task automatic consume_one(input longint unsigned head, output bit got);
    longint unsigned ts, w1, rlen;
    int clen, wlen, flags, drops, nb, p;
    got = 0;
    if (head - tail < 16) return;
    ts = r64(tail); w1 = r64(tail + 8);
    clen = w1[15:0]; wlen = w1[31:16]; flags = w1[39:32]; p = w1[47:40]; drops = w1[63:48];
    rlen = 16 + ((clen + 7) / 8) * 8;
    if (head - tail < rlen) return;
    got = 1;
    if (p > 1 || !chk_port_ok[p]) begin
      $display("ERROR: rec %0d from port %0d (not expected)", recs, p); errors++;
      recs++; tail += rlen; return;
    end
    if (ts < last_ts[p]) begin $display("ERROR: port %0d timestamp went back", p); errors++; end
    last_ts[p] = ts;
    drops_p[p] += drops;
    if (chk_tg) begin
      longint unsigned seq = r64(tail + 16 + 16);
      reg [47:0] src;
      for (int i = 0; i < 6; i++) src[8*(5-i) +: 8] = rb(tail + 16 + 6 + i);
      if (src != (48'h024b_3700_006e | (longint'(p) << 8))) begin
        $display("ERROR: port %0d generator frame with src %h", p, src); errors++;
      end
      if (seq != tg_next[p] + drops) begin
        $display("ERROR: port %0d tg seq %0d expected %0d (+%0d drops)", p, seq, tg_next[p], drops); errors++;
      end
      tg_next[p] = seq + 1;
    end else begin
      frame_t f;
      // skip frames the ring cannot contain: bad ones (unless kept) and dropped ones
      while (exp_idx[p] < sent_size(p) && sent_bad(p, exp_idx[p]) && !chk_keep_bad) exp_idx[p]++;
      for (int d = 0; d < drops; d++) begin
        exp_idx[p]++;
        while (exp_idx[p] < sent_size(p) && sent_bad(p, exp_idx[p]) && !chk_keep_bad) exp_idx[p]++;
      end
      if (exp_idx[p] >= sent_size(p)) begin $display("ERROR: port %0d record with no frame", p); errors++; recs++; tail += rlen; return; end
      if (p == 0) f = sent_a[exp_idx[p]]; else f = sent_b[exp_idx[p]];
      exp_idx[p]++;
      nb = chk_keep_fcs ? f.b.size() : f.b.size() - 4;
      if (wlen != nb) begin $display("ERROR: port %0d rec %0d wire len %0d expected %0d", p, recs, wlen, nb); errors++; end
      if (clen != (nb > chk_snap ? chk_snap : nb)) begin $display("ERROR: port %0d cap len %0d", p, clen); errors++; end
      if (flags[0] != f.bad || flags[1] != (nb > chk_snap) || flags[2] != chk_keep_fcs) begin
        $display("ERROR: port %0d rec %0d flags %h (bad %0d)", p, recs, flags, f.bad); errors++;
      end
      for (int i = 0; i < clen; i++)
        if (rb(tail + 16 + i) != f.b[i]) begin
          $display("ERROR: port %0d rec %0d (seq %0d) byte %0d = %h expected %h", p, recs, f.seq, i, rb(tail + 16 + i), f.b[i]);
          errors++; break;
        end
    end
    recs++;
    recs_p[p]++;
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

  task automatic setup(input [31:0] ctrl, input [31:0] snap, input [1:0] ports);
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
    wr(12'h148, ports);
    wr(12'h100, ctrl & ~32'h1);       // release reset, configure
    repeat (20) @(posedge clk);
    tail = 0; recs = 0;
    for (int p = 0; p < 2; p++) begin
      recs_p[p] = 0; drops_p[p] = 0; last_ts[p] = 0; tg_next[p] = 0; exp_idx[p] = 0;
      chk_port_ok[p] = ports[p];
    end
    sent_a.delete(); sent_b.delete();
    for (longint unsigned a = STAT; a < STAT + 8; a++) mem.delete(a);
    wr(12'h100, ctrl | 32'h1);        // enable
  endtask

  // FPGA counters of one port: A at 0x150.. (TG_SEQ 0x190), B at 0x1A0.. (TG_SEQ 0x1C8)
  task automatic port_counters(input int p, output reg [63:0] rxf, cap, drop, bad, tg);
    reg [11:0] b; b = (p == 0) ? 12'h150 : 12'h1A0;
    rd64(b, rxf); rd64(b + 12'h10, cap); rd64(b + 12'h18, drop); rd64(b + 12'h20, bad);
    rd64((p == 0) ? 12'h190 : 12'h1C8, tg);
  endtask

  task automatic report(input string name);
    reg [63:0] rxf, cap, drop, bad, tg, rec, tl, st;
    rd64(12'h178, rec); rd64(12'h180, tl); rd64(12'h188, st);
    $display("%s: records %0d tlps %0d (tb %0d) stalls %0d | host recs %0d tail %0d errors %0d",
             name, rec, tl, tlps, st, recs, tail, errors);
    for (int p = 0; p < 2; p++) begin
      port_counters(p, rxf, cap, drop, bad, tg);
      $display("  port %s: rx %0d cap %0d drop %0d bad %0d tg %0d | host recs %0d drops-in-records %0d",
               p ? "B" : "A", rxf, cap, drop, bad, tg, recs_p[p], drops_p[p]);
      if (cap != recs_p[p]) begin $display("ERROR: port %0d FPGA captured %0d, host got %0d", p, cap, recs_p[p]); errors++; end
      if (drops_p[p] > drop) begin $display("ERROR: port %0d records report %0d drops, FPGA %0d", p, drops_p[p], drop); errors++; end
    end
    if (rec != recs) begin $display("ERROR: RECORDS %0d host %0d", rec, recs); errors++; end
  endtask

  function automatic int good_frames(input int p);
    int g = 0;
    for (int i = 0; i < sent_size(p); i++) if (!sent_bad(p, i)) g++;
    return g;
  endfunction

  initial begin
    reg [31:0] v;
    reg [63:0] rxf, cap, drop, bad, tg;
    repeat (10) @(posedge clk);
    rst = 0;
    repeat (10) @(posedge rx_clk_a);
    rx_rst = 0;
    rd(12'h000, v);
    rd(12'h148, v);
    if (v != 1) begin $display("ERROR: PORTS reset value %0d", v); errors++; end

    // ---- 1: both ports, XGMII frames, FCS stripped, bad frames discarded, fast host ----
    chk_keep_bad = 0; chk_keep_fcs = 0; chk_tg = 0; chk_snap = 9600;
    setup(32'h0, 9600, 2'b11);
    fork
      send_frames(0, 300, 60, 1455, 10);
      send_frames(1, 300, 60, 1455, 10);
      consumer(1000000, 500);
    join_any
    repeat (2000) @(posedge clk);
    consumer(1000000, 40);
    repeat (40000) @(posedge rx_clk_a);   // counter snapshot interval
    report("phase 1");
    for (int p = 0; p < 2; p++)
      if (recs_p[p] != good_frames(p) || drops_p[p] != 0) begin
        $display("ERROR: phase 1 port %0d got %0d records, %0d good frames sent", p, recs_p[p], good_frames(p)); errors++;
      end

    // ---- 2: both ports, FCS kept, bad frames kept, snaplen 128, slow host (ring full -> drops) ----
    chk_keep_bad = 1; chk_keep_fcs = 1; chk_snap = 128;
    setup(32'h0C, 128, 2'b11);
    consume_delay = 300;
    ready_pct = 70;
    fork
      send_frames(0, 3000, 60, 200, 8);
      send_frames(1, 3000, 60, 200, 8);
      consumer(1000000, 1000);
    join_any
    $display("phase 2 slow part ended at %0t, recs %0d (A %0d, B %0d)", $time, recs, recs_p[0], recs_p[1]);
    consume_delay = 0;
    consumer(1000000, 2000);
    repeat (40000) @(posedge rx_clk_a);
    report("phase 2");
    for (int p = 0; p < 2; p++) begin
      port_counters(p, rxf, cap, drop, bad, tg);
      if (drop == 0) begin $display("ERROR: phase 2 port %0d: no drops, the test did not overload it", p); errors++; end
      if (recs_p[p] + drop != sent_size(p)) begin
        $display("ERROR: phase 2 port %0d records %0d + FPGA drops %0d != frames sent %0d", p, recs_p[p], drop, sent_size(p)); errors++;
      end
    end

    // ---- 3: both generators at line rate (60 B, gap 3): 2 x 14.2 Mframes/s > the DMA path ----
    chk_keep_bad = 0; chk_keep_fcs = 0; chk_tg = 1; chk_snap = 9600;
    ready_pct = 100;
    wr(12'h140, {16'd3, 16'd60});
    setup(32'h10, 9600, 2'b11);
    consumer(30000, 2000);
    wr(12'h100, 32'h10);          // disable
    consumer(1000000, 3000);      // both FIFOs are full here: ~7000 records to drain
    repeat (40000) @(posedge rx_clk_a);
    report("phase 3");
    for (int p = 0; p < 2; p++) begin
      port_counters(p, rxf, cap, drop, bad, tg);
      if (tg != rxf || tg != cap + drop || cap != recs_p[p]) begin
        $display("ERROR: phase 3 port %0d TG_SEQ %0d rx %0d captured %0d dropped %0d records %0d", p, tg, rxf, cap, drop, recs_p[p]); errors++;
      end
      if (recs_p[p] * 10 < recs * 4) begin
        $display("ERROR: phase 3 port %0d got only %0d of %0d records (merge not fair)", p, recs_p[p], recs); errors++;
      end
    end

    // ---- 4: port B only, frames on both ports: nothing from A may appear ----
    chk_keep_bad = 0; chk_keep_fcs = 0; chk_tg = 0; chk_snap = 9600;
    setup(32'h0, 9600, 2'b10);
    fork
      send_frames(0, 200, 60, 1455, 10);
      send_frames(1, 200, 60, 1455, 10);
      consumer(1000000, 400);
    join_any
    repeat (2000) @(posedge clk);
    consumer(1000000, 40);
    repeat (40000) @(posedge rx_clk_a);
    report("phase 4");
    port_counters(0, rxf, cap, drop, bad, tg);
    if (recs_p[0] != 0 || cap != 0 || drop != 0 || rxf != sent_size(0)) begin
      $display("ERROR: phase 4 port A (disabled): records %0d captured %0d dropped %0d rx %0d of %0d", recs_p[0], cap, drop, rxf, sent_size(0)); errors++;
    end
    if (recs_p[1] != good_frames(1)) begin $display("ERROR: phase 4 port B got %0d of %0d", recs_p[1], good_frames(1)); errors++; end

    // ---- 5: port A generator alone at line rate: no drops (as k7_cap) ----
    chk_tg = 1;
    setup(32'h10, 9600, 2'b01);
    consumer(20000, 1500);
    wr(12'h100, 32'h10);
    consumer(1000000, 40);
    repeat (40000) @(posedge rx_clk_a);
    report("phase 5");
    port_counters(0, rxf, cap, drop, bad, tg);
    if (drop != 0 || recs_p[0] != tg || recs_p[1] != 0) begin
      $display("ERROR: phase 5 drops %0d records %0d generated %0d (B records %0d)", drop, recs_p[0], tg, recs_p[1]); errors++;
    end

    if (errors == 0) $display("PASS"); else $display("FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
