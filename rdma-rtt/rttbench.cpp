// rttbench: application-level ping-pong RTT over TCP, UDP and RDMA (RC).
//   server:  rttbench server CONTROL_IP
//   client:  rttbench client CONTROL_IP [--iters N] [--rounds N] [--awake] [--csv F]
// The server echoes every message. Only the client takes timestamps, so no
// clock sync is needed. Hot loops do not allocate.
#include <infiniband/verbs.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>
#include <immintrin.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cinttypes>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
using u64 = uint64_t; using u32 = uint32_t; using u8 = uint8_t;
static constexpr int CTRL_PORT = 18600, WARM = 2000, SLOTS = 64, MAXSZ = 8192;
static constexpr u64 STOP = ~0ull;
static std::string dev = "mlx5_1"; static int gidx = 3, cpu = 2;

[[noreturn]] static void die(const char* f, ...) {
  va_list a; va_start(a, f); vfprintf(stderr, f, a); va_end(a);
  fprintf(stderr, " (errno: %s)\n", strerror(errno)); exit(1);
}
#define CHK(x) do { if (!(x)) die("%s:%d failed: %s", __FILE__, __LINE__, #x); } while (0)
static inline u64 now() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000ull + t.tv_nsec; }
static inline u64 head(const u8* p) { u64 v; memcpy(&v, p, 8); return v; }
// Message: 8-byte sequence at the start, sequence low byte as the last byte.
static inline void stamp(u8* p, int n, u64 s) { memcpy(p, &s, 8); p[n - 1] = (u8)s; }

struct Ctl {                     // newline-framed text control channel
  int fd;
  void send(const std::string& s) { std::string m = s + "\n"; CHK(::send(fd, m.data(), m.size(), MSG_NOSIGNAL) == (ssize_t)m.size()); }
  bool line(std::string& o) { o.clear(); char c; while (true) { ssize_t r = ::recv(fd, &c, 1, 0); if (r <= 0) return false; if (c == '\n') return true; o += c; } }
  std::string need() { std::string s; CHK(line(s)); return s; }
};
static sockaddr_in sa(const char* ip, int port) {
  sockaddr_in a{}; a.sin_family = AF_INET; a.sin_port = htons(port); CHK(inet_pton(AF_INET, ip, &a.sin_addr) == 1); return a;
}
static void one(int fd, int lvl, int opt) { int v = 1; CHK(!setsockopt(fd, lvl, opt, &v, sizeof v)); }
static int bound_port(int fd) { sockaddr_in a; socklen_t l = sizeof a; CHK(!getsockname(fd, (sockaddr*)&a, &l)); return ntohs(a.sin_port); }

// ---------- sockets ----------
static void tcp_read(int fd, u8* b, int n, bool spin) {
  int got = 0;
  while (got < n) {
    ssize_t r = recv(fd, b + got, n - got, spin ? MSG_DONTWAIT : MSG_WAITALL);
    if (r > 0) got += r;
    else if (r < 0 && (errno == EAGAIN || errno == EINTR)) { if (spin) _mm_pause(); else if (errno == EAGAIN) die("tcp recv timeout"); }
    else die("tcp closed");
  }
}
static void tcp_write(int fd, const u8* b, int n) {
  while (n) { ssize_t r = send(fd, b, n, MSG_NOSIGNAL); CHK(r > 0); b += r; n -= r; }
}
// returns bytes, or -1 on timeout
static ssize_t udp_read(int fd, u8* b, bool spin) {
  if (!spin) { ssize_t r = recv(fd, b, MAXSZ, 0); if (r < 0 && errno != EAGAIN) die("udp recv"); return r; }
  u64 dl = 0;
  for (u32 i = 1;; ++i) {
    ssize_t r = recv(fd, b, MAXSZ, MSG_DONTWAIT);
    if (r >= 0) return r;
    if (errno != EAGAIN) die("udp recv");
    _mm_pause();
    if ((i & 0xfff) == 0) { u64 t = now(); if (!dl) dl = t + 500000000ull; else if (t > dl) return -1; }
  }
}
static void rcv_to(int fd, int ms) { timeval t{ms / 1000, (ms % 1000) * 1000}; CHK(!setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t)); }

// ---------- RDMA ----------
struct Info { u32 qpn, psn, rkey; u64 addr; char gid[33]; };
struct Rdma {
  ibv_context* ctx{}; ibv_pd* pd{}; ibv_cq *scq{}, *rcq{}; ibv_comp_channel* ch{}; ibv_qp* qp{}; ibv_mr* mr{};
  u8 *buf{}, *rx{}, *tx{}; size_t len = (SLOTS + 1) * (size_t)MAXSZ; u32 inl = 0, psn = 0; Info peer{};
  bool owe = false;            // a signalled send completion has not been reaped
  void open(bool event) {
    int n; ibv_device** l = ibv_get_device_list(&n); CHK(l);
    for (int i = 0; i < n; i++) if (dev == ibv_get_device_name(l[i])) ctx = ibv_open_device(l[i]);
    ibv_free_device_list(l); if (!ctx) die("no RDMA device %s", dev.c_str());
    CHK(pd = ibv_alloc_pd(ctx));
    buf = (u8*)mmap(nullptr, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0); CHK(buf != MAP_FAILED);
    rx = buf; tx = buf + SLOTS * (size_t)MAXSZ;
    CHK(mr = ibv_reg_mr(pd, buf, len, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ));
    if (event) CHK(ch = ibv_create_comp_channel(ctx));
    CHK(scq = ibv_create_cq(ctx, 256, nullptr, nullptr, 0)); CHK(rcq = ibv_create_cq(ctx, 256, nullptr, ch, 0));
    if (event) CHK(!ibv_req_notify_cq(rcq, 0));
    ibv_qp_init_attr a{}; a.send_cq = scq; a.recv_cq = rcq; a.qp_type = IBV_QPT_RC;
    a.cap.max_send_wr = 256; a.cap.max_recv_wr = SLOTS; a.cap.max_send_sge = a.cap.max_recv_sge = 1; a.cap.max_inline_data = 200;
    CHK(qp = ibv_create_qp(pd, &a)); inl = a.cap.max_inline_data; psn = lrand48() & 0xffffff;
    ibv_qp_attr q{}; q.qp_state = IBV_QPS_INIT; q.port_num = 1; q.qp_access_flags = IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ;
    CHK(!ibv_modify_qp(qp, &q, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS));
    for (int i = 0; i < SLOTS; i++) post_recv(i);
  }
  void post_recv(int s) {
    ibv_sge g{(u64)(rx + s * (size_t)MAXSZ), MAXSZ, mr->lkey}; ibv_recv_wr w{}, *bad; w.wr_id = s; w.sg_list = &g; w.num_sge = 1;
    CHK(!ibv_post_recv(qp, &w, &bad));
  }
  std::string info() {
    ibv_gid g; CHK(!ibv_query_gid(ctx, 1, gidx, &g)); char h[33]; for (int i = 0; i < 16; i++) sprintf(h + 2 * i, "%02x", g.raw[i]);
    char o[160]; snprintf(o, sizeof o, "%u %u %u %" PRIu64 " %s", qp->qp_num, psn, mr->rkey, (u64)buf, h); return o;
  }
  void connect(const std::string& s) {
    CHK(sscanf(s.c_str(), "%u %u %u %" SCNu64 " %32s", &peer.qpn, &peer.psn, &peer.rkey, &peer.addr, peer.gid) == 5);
    ibv_qp_attr a{}; a.qp_state = IBV_QPS_RTR; a.path_mtu = IBV_MTU_4096; a.dest_qp_num = peer.qpn; a.rq_psn = peer.psn;
    a.max_dest_rd_atomic = 1; a.min_rnr_timer = 12; a.ah_attr.is_global = 1; a.ah_attr.port_num = 1;
    for (int i = 0; i < 16; i++) { unsigned v; sscanf(peer.gid + 2 * i, "%2x", &v); a.ah_attr.grh.dgid.raw[i] = v; }
    a.ah_attr.grh.sgid_index = gidx; a.ah_attr.grh.hop_limit = 64;
    CHK(!ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER));
    ibv_qp_attr b{}; b.qp_state = IBV_QPS_RTS; b.timeout = 14; b.retry_cnt = 7; b.rnr_retry = 7; b.sq_psn = psn; b.max_rd_atomic = 1;
    CHK(!ibv_modify_qp(qp, &b, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC));
  }
  static void ok(const ibv_wc& w) { if (w.status != IBV_WC_SUCCESS) die("RDMA completion: %s", ibv_wc_status_str(w.status)); }
  void poll(ibv_cq* c, ibv_wc& w) { int n; while ((n = ibv_poll_cq(c, 1, &w)) == 0) _mm_pause(); CHK(n == 1); ok(w); }
  // Reap the previous signalled send (one in 32) before the timed region.
  void prep(u64 seq) { if ((seq & 31) == 0 && owe) { ibv_wc w; poll(scq, w); owe = false; } }
  void post(ibv_wr_opcode op, u8* p, int n, u64 seq, bool force_sig = false) {
    ibv_sge g{(u64)p, (u32)n, mr->lkey}; ibv_send_wr w{}, *bad; w.sg_list = &g; w.num_sge = 1; w.opcode = op;
    bool sig = force_sig || (seq & 31) == 0;
    w.send_flags = (sig ? IBV_SEND_SIGNALED : 0) | (op != IBV_WR_RDMA_READ && (u32)n <= inl ? IBV_SEND_INLINE : 0);
    w.wr.rdma.remote_addr = peer.addr; w.wr.rdma.rkey = peer.rkey;
    CHK(!ibv_post_send(qp, &w, &bad)); if (sig && !force_sig) owe = true;
  }
  void recv_wc(ibv_wc& w, bool event) {
    if (!event) { poll(rcq, w); return; }
    while (true) {
      int n = ibv_poll_cq(rcq, 1, &w); CHK(n >= 0); if (n) { ok(w); return; }
      CHK(!ibv_req_notify_cq(rcq, 0));
      n = ibv_poll_cq(rcq, 1, &w); CHK(n >= 0); if (n) { ok(w); return; }   // close arm/arrive race
      ibv_cq* c; void* x; CHK(!ibv_get_cq_event(ch, &c, &x)); ibv_ack_cq_events(c, 1);
    }
  }
  // RDMA WRITE arrival: RC on x86/mlx5 places the last byte last (as perftest assumes).
  void wait_tag(int n, u64 seq) {
    volatile u8* p = rx + n - 1; while (*p != (u8)seq) _mm_pause();
    std::atomic_thread_fence(std::memory_order_acquire); CHK(head(rx) == seq);
  }
  ~Rdma() {
    if (qp) ibv_destroy_qp(qp);
    if (scq) ibv_destroy_cq(scq);
    if (rcq) ibv_destroy_cq(rcq);
    if (ch) ibv_destroy_comp_channel(ch);
    if (mr) ibv_dereg_mr(mr);
    if (pd) ibv_dealloc_pd(pd);
    if (ctx) ibv_close_device(ctx);
    if (buf) munmap(buf, len);
  }
};

// ---------- server ----------
static void serve(const char* ip) {
  int l = socket(AF_INET, SOCK_STREAM, 0); one(l, SOL_SOCKET, SO_REUSEADDR); auto a = sa(ip, CTRL_PORT);
  CHK(!bind(l, (sockaddr*)&a, sizeof a)); CHK(!listen(l, 1)); printf("listening %s:%d\n", ip, CTRL_PORT); fflush(stdout);
  Ctl c{accept(l, nullptr, nullptr)}; CHK(c.fd >= 0); one(c.fd, IPPROTO_TCP, TCP_NODELAY);
  alignas(64) static u8 b[MAXSZ]; std::string s;
  while (c.line(s)) {
    if (s == "QUIT") break;
    char kind[16], data[32]; int spin, n; u64 total;
    CHK(sscanf(s.c_str(), "RUN %15s %d %d %" SCNu64 " %31s", kind, &spin, &n, &total, data) == 5); CHK(n >= 16 && n <= MAXSZ);
    alarm(120); std::string k = kind;
    if (k == "tcp") {
      int ls = socket(AF_INET, SOCK_STREAM, 0); auto d = sa(data, 0); CHK(!bind(ls, (sockaddr*)&d, sizeof d)); CHK(!listen(ls, 1));
      c.send(std::to_string(bound_port(ls))); int f = accept(ls, nullptr, nullptr); CHK(f >= 0); one(f, IPPROTO_TCP, TCP_NODELAY);
      for (u64 i = 0; i < total; i++) { tcp_read(f, b, n, spin); tcp_write(f, b, n); }
      c.need(); close(f); close(ls);
    } else if (k == "udp") {
      int f = socket(AF_INET, SOCK_DGRAM, 0); auto d = sa(data, 0); CHK(!bind(f, (sockaddr*)&d, sizeof d)); rcv_to(f, 2000);
      c.send(std::to_string(bound_port(f)));
      sockaddr_in p = sa(c.need().c_str(), 0); { int port = atoi(c.need().c_str()); p.sin_port = htons(port); }
      CHK(!connect(f, (sockaddr*)&p, sizeof p)); c.send("GO");
      while (true) { ssize_t r = udp_read(f, b, spin); if (r < 0 || (r >= 8 && head(b) == STOP)) break; CHK(send(f, b, r, 0) == r); }
      c.need(); close(f);
    } else {
      bool ev = !spin; Rdma r; r.open(ev); c.send(r.info()); r.connect(c.need()); c.send("GO");
      for (u64 i = 1; i <= total; i++) {
        if (k == "write") { r.wait_tag(n, i); r.prep(i); r.post(IBV_WR_RDMA_WRITE, r.rx, n, i); }
        else if (k == "send") { ibv_wc w; r.recv_wc(w, ev); r.prep(i); r.post(IBV_WR_SEND, r.rx + w.wr_id * (size_t)MAXSZ, n, i); r.post_recv(w.wr_id); }
        else break;              // read: remote CPU not involved
      }
      c.need();
    }
    alarm(0);
  }
}

// ---------- client ----------
struct Test { const char *name, *kind; bool spin, portA; };
static const Test tests[] = {
  {"A tcp  blocking", "tcp", false, true}, {"A tcp  polling", "tcp", true, true},
  {"A udp  blocking", "udp", false, true}, {"A udp  polling", "udp", true, true},
  {"B tcp  blocking", "tcp", false, false}, {"B tcp  polling", "tcp", true, false},
  {"B udp  blocking", "udp", false, false}, {"B udp  polling", "udp", true, false},
  {"B rdma send blocking", "send", false, false}, {"B rdma send polling", "send", true, false},
  {"B rdma write polling", "write", true, false}, {"B rdma read polling", "read", true, false}};
static const int sizes[] = {16, 64, 256, 1024, 4096, 8192};

static u64 run(Ctl& c, const Test& t, int n, u64 iters, const char* srv, const char* me, std::vector<u32>& out) {
  alignas(64) static u8 tx[MAXSZ], rb[MAXSZ]; memset(tx, 0x5a, n);
  u64 total = iters + WARM, lost = 0; std::string k = t.kind; char m[128];
  size_t base = out.size(); out.resize(base + iters); u32* res = out.data() + base; u64 cnt = 0;   // pre-touched
  auto rec = [&](u64 i, u64 dt) { if (i > WARM) res[cnt++] = (u32)std::min<u64>(dt, UINT32_MAX); };
  alarm(120); snprintf(m, sizeof m, "RUN %s %d %d %" PRIu64 " %s", t.kind, t.spin, n, total, srv); c.send(m);
  if (k == "tcp") {
    int port = atoi(c.need().c_str()); int f = socket(AF_INET, SOCK_STREAM, 0); auto l = sa(me, 0), d = sa(srv, port);
    CHK(!bind(f, (sockaddr*)&l, sizeof l)); CHK(!connect(f, (sockaddr*)&d, sizeof d)); one(f, IPPROTO_TCP, TCP_NODELAY);
    for (u64 i = 1; i <= total; i++) { stamp(tx, n, i); u64 a = now(); tcp_write(f, tx, n); tcp_read(f, rb, n, t.spin); rec(i, now() - a); CHK(head(rb) == i && rb[n - 1] == (u8)i); }
    c.send("DONE"); close(f);
  } else if (k == "udp") {
    int port = atoi(c.need().c_str()); int f = socket(AF_INET, SOCK_DGRAM, 0); auto l = sa(me, 0), d = sa(srv, port);
    CHK(!bind(f, (sockaddr*)&l, sizeof l)); CHK(!connect(f, (sockaddr*)&d, sizeof d)); rcv_to(f, 500);
    c.send(me); c.send(std::to_string(bound_port(f))); CHK(c.need() == "GO");
    for (u64 i = 1; i <= total; i++) {
      stamp(tx, n, i); u64 a = now(); CHK(send(f, tx, n, 0) == n);
      while (true) { ssize_t r = udp_read(f, rb, t.spin); if (r < 0) { lost++; break; } if (r == n && head(rb) == i) { rec(i, now() - a); CHK(rb[n - 1] == (u8)i); break; } }
    }
    stamp(tx, n, STOP); for (int i = 0; i < 3; i++) (void)!send(f, tx, n, 0);
    c.send("DONE"); close(f);
  } else {
    bool ev = !t.spin; Rdma r; r.open(ev); std::string p = c.need(); c.send(r.info()); r.connect(p); CHK(c.need() == "GO");
    memset(r.tx, 0x5a, n);
    for (u64 i = 1; i <= total; i++) {
      stamp(r.tx, n, i);
      if (k == "write") { r.prep(i); u64 a = now(); r.post(IBV_WR_RDMA_WRITE, r.tx, n, i); r.wait_tag(n, i); rec(i, now() - a); }
      else if (k == "send") {
        ibv_wc w; r.prep(i); u64 a = now(); r.post(IBV_WR_SEND, r.tx, n, i); r.recv_wc(w, ev); rec(i, now() - a);
        u8* q = r.rx + w.wr_id * (size_t)MAXSZ; CHK((int)w.byte_len == n && head(q) == i && q[n - 1] == (u8)i); r.post_recv(w.wr_id);
      } else { ibv_wc w; u64 a = now(); r.post(IBV_WR_RDMA_READ, r.tx, n, i, true); r.poll(r.scq, w); rec(i, now() - a); }
    }
    c.send("DONE");
  }
  alarm(0); out.resize(base + cnt); return lost;
}

int main(int argc, char** argv) {
  if (argc < 3) die("usage: rttbench server|client CONTROL_IP [options]");
  std::string role = argv[1]; const char* ip = argv[2]; u64 iters = 20000; int rounds = 3; bool awake = false; std::string csv;
  for (int i = 3; i < argc; i++) {
    std::string o = argv[i]; auto v = [&] { CHK(i + 1 < argc); return argv[++i]; };
    if (o == "--iters") iters = atoll(v()); else if (o == "--rounds") rounds = atoi(v()); else if (o == "--awake") awake = true;
    else if (o == "--csv") csv = v(); else if (o == "--dev") dev = v(); else if (o == "--gid") gidx = atoi(v()); else if (o == "--cpu") cpu = atoi(v());
    else die("unknown option %s", o.c_str());
  }
  cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(cpu, &cs); CHK(!sched_setaffinity(0, sizeof cs, &cs));
  srand48(now()); if (mlockall(MCL_CURRENT | MCL_FUTURE)) fprintf(stderr, "note: mlockall unavailable\n");
  if (awake) { int f = open("/dev/cpu_dma_latency", O_WRONLY); CHK(f >= 0); int32_t z = 0; CHK(write(f, &z, 4) == 4); } // held until exit
  if (role == "server") { serve(ip); return 0; }
  Ctl c{socket(AF_INET, SOCK_STREAM, 0)}; auto d = sa(ip, CTRL_PORT); CHK(!connect(c.fd, (sockaddr*)&d, sizeof d)); one(c.fd, IPPROTO_TCP, TCP_NODELAY);
  constexpr int NT = sizeof tests / sizeof *tests, NS = sizeof sizes / sizeof *sizes;
  std::vector<std::vector<u32>> all(NT * NS); std::vector<std::vector<u32>> meds(NT * NS); std::vector<u64> lost(NT * NS);
  for (auto& v : all) v.reserve(iters * rounds);
  for (int r = 0; r < rounds; r++)                        // interleave transports
    for (int s = 0; s < NS; s++) for (int t = 0; t < NT; t++) {
      auto& v = all[t * NS + s]; size_t b = v.size(); bool A = tests[t].portA;
      lost[t * NS + s] += run(c, tests[t], sizes[s], iters, A ? "10.25.0.1" : "10.26.0.1", A ? "10.25.0.2" : "10.26.0.2", v);
      std::vector<u32> w(v.begin() + b, v.end()); if (w.empty()) die("no samples"); std::nth_element(w.begin(), w.begin() + w.size() / 2, w.end()); meds[t * NS + s].push_back(w[w.size() / 2]);
    }
  c.send("QUIT");
  FILE* o = csv.empty() ? nullptr : fopen(csv.c_str(), "w"); if (!csv.empty()) CHK(o);
  if (o) fprintf(o, "test,bytes,n,min_us,p50_us,p99_us,p999_us,max_us,round_p50_lo,round_p50_hi,lost\n");
  for (int s = 0; s < NS; s++) {
    printf("\n%d bytes  (RTT us, %d rounds x %" PRIu64 ")\n%-22s %8s %8s %8s %8s %9s  %15s %5s\n", sizes[s], rounds, iters, "test", "min", "p50", "p99", "p99.9", "max", "p50 per-round", "lost");
    for (int t = 0; t < NT; t++) {
      auto& v = all[t * NS + s]; std::sort(v.begin(), v.end()); auto q = [&](double p) { return v[(size_t)(p * (v.size() - 1))] / 1e3; };
      auto [lo, hi] = std::minmax_element(meds[t * NS + s].begin(), meds[t * NS + s].end());
      printf("%-22s %8.2f %8.2f %8.2f %8.2f %9.2f  %6.2f - %6.2f %5" PRIu64 "\n", tests[t].name, q(0), q(.5), q(.99), q(.999), q(1), *lo / 1e3, *hi / 1e3, lost[t * NS + s]);
      if (o) fprintf(o, "%s,%d,%zu,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%" PRIu64 "\n", tests[t].name, sizes[s], v.size(), q(0), q(.5), q(.99), q(.999), q(1), *lo / 1e3, *hi / 1e3, lost[t * NS + s]);
    }
  }
  if (o) fclose(o);
}
