// flood: overload a receiver over UDP, RC RDMA SEND or UD RDMA SEND, and account for every message.
//   rx: flood rx CTRL_IP DATA_IP IFACE        tx: flood tx CTRL_IP DATA_DST DATA_SRC MODE SIZE SECS FLOWS RCVBUF DELAY_NS
// MODE udp|rc|ud. Each message carries a sequence and a tag; rx counts received, gaps and corruption.
#include <infiniband/verbs.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>
#include <immintrin.h>
#include <atomic>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <memory>
#include <string>
#include <thread>
#include <vector>
using u64 = uint64_t; using u32 = uint32_t; using u8 = uint8_t;
static const char* DEV = "mlx5_1"; static int GIDX = 3; static constexpr int DEPTH = 512, BATCH = 16, PORT = 18700, UPORT = 18800, GRH = 40;
[[noreturn]] static void die(const char* f, ...) { va_list a; va_start(a, f); vfprintf(stderr, f, a); va_end(a); fprintf(stderr, " (%s)\n", strerror(errno)); _exit(1); }
#define CHK(x) do { if (!(x)) die("%s:%d %s", __FILE__, __LINE__, #x); } while (0)
static u64 now() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000ull + t.tv_nsec; }
static double cpu_s() { rusage r; getrusage(RUSAGE_SELF, &r); return r.ru_utime.tv_sec + r.ru_stime.tv_sec + (r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6; }
static sockaddr_in sa(const char* ip, int p) { sockaddr_in a{}; a.sin_family = AF_INET; a.sin_port = htons(p); CHK(inet_pton(AF_INET, ip, &a.sin_addr) == 1); return a; }
static void put(int fd, std::string s) { s += "\n"; CHK(send(fd, s.data(), s.size(), MSG_NOSIGNAL) == (ssize_t)s.size()); }
static bool get(int fd, std::string& o) { o.clear(); char c; while (recv(fd, &c, 1, 0) == 1) { if (c == '\n') return true; o += c; } return false; }
static std::string need(int fd) { std::string s; if (!get(fd, s)) die("control channel closed"); return s; }
static void spin_ns(u64 d) { if (!d) return; u64 e = now() + d; while (now() < e) _mm_pause(); }
static void stamp(u8* p, int n, u64 s) { memcpy(p, &s, 8); p[n - 1] = (u8)s; }
struct alignas(64) Stat { u64 rx = 0, bad = 0, gaps = 0, next = 1; };
static void check(Stat& s, const u8* p, int len, int n) {
  if (len != n) { s.bad++; return; } u64 q; memcpy(&q, p, 8); if (p[n - 1] != (u8)q) s.bad++;
  if (q != s.next) s.gaps++;
  s.next = q + 1; s.rx++;
}
struct Cfg { char mode[8]; int size, secs, flows, rcvbuf; u64 delay; };

struct Qp {                                  // one flow
  ibv_context* ctx{}; ibv_pd* pd{}; ibv_cq* cq{}; ibv_qp* qp{}; ibv_mr* mr{}; ibv_ah* ah{}; u8* buf{}; int slot, n; bool ud, rxside; u32 inl = 0, rq = 0;
  void open(bool ud_, bool rx, int size) {
    ud = ud_; rxside = rx; n = size; slot = (size + GRH + 63) & ~63; int k; auto l = ibv_get_device_list(&k); CHK(l);
    for (int i = 0; i < k; i++) if (!strcmp(DEV, ibv_get_device_name(l[i]))) ctx = ibv_open_device(l[i]);
    ibv_free_device_list(l); CHK(ctx); CHK(pd = ibv_alloc_pd(ctx));
    size_t len = (size_t)slot * DEPTH; buf = (u8*)mmap(0, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0); CHK(buf != MAP_FAILED);
    memset(buf, 0x5a, len); CHK(mr = ibv_reg_mr(pd, buf, len, IBV_ACCESS_LOCAL_WRITE)); CHK(cq = ibv_create_cq(ctx, DEPTH * 2, 0, 0, 0));
    ibv_qp_init_attr a{}; a.send_cq = a.recv_cq = cq; a.qp_type = ud ? IBV_QPT_UD : IBV_QPT_RC; a.cap.max_send_wr = rx ? 1 : DEPTH; a.cap.max_recv_wr = rx ? DEPTH : 1;
    a.cap.max_send_sge = a.cap.max_recv_sge = 1; a.cap.max_inline_data = rx ? 0 : 64; CHK(qp = ibv_create_qp(pd, &a)); inl = a.cap.max_inline_data;
    ibv_qp_attr q{}; q.qp_state = IBV_QPS_INIT; q.port_num = 1; q.qkey = 0x1234;
    CHK(!ibv_modify_qp(qp, &q, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | (ud ? IBV_QP_QKEY : IBV_QP_ACCESS_FLAGS)));
    if (rx) { int s[BATCH]; for (int i = 0; i < DEPTH; i += BATCH) { for (int j = 0; j < BATCH; j++) s[j] = i + j; post_recv(s, BATCH); } }
  }
  std::string info() { ibv_gid g; CHK(!ibv_query_gid(ctx, 1, GIDX, &g)); char h[33]; for (int i = 0; i < 16; i++) sprintf(h + 2 * i, "%02x", g.raw[i]); return std::to_string(qp->qp_num) + " " + h; }
  void connect(const std::string& s) {
    char h[33]; CHK(sscanf(s.c_str(), "%u %32s", &rq, h) == 2); ibv_ah_attr ha{}; ha.is_global = 1; ha.port_num = 1; ha.grh.sgid_index = GIDX; ha.grh.hop_limit = 64;
    for (int i = 0; i < 16; i++) { unsigned v; sscanf(h + 2 * i, "%2x", &v); ha.grh.dgid.raw[i] = v; }
    ibv_qp_attr a{}; a.qp_state = IBV_QPS_RTR; a.path_mtu = IBV_MTU_4096; a.dest_qp_num = rq; a.max_dest_rd_atomic = 1; a.min_rnr_timer = 1; a.ah_attr = ha;
    CHK(!ibv_modify_qp(qp, &a, ud ? IBV_QP_STATE : IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER));
    ibv_qp_attr b{}; b.qp_state = IBV_QPS_RTS; b.timeout = 14; b.retry_cnt = 7; b.rnr_retry = 7; b.max_rd_atomic = 1;   // rnr_retry 7 = wait forever for receiver
    CHK(!ibv_modify_qp(qp, &b, IBV_QP_STATE | IBV_QP_SQ_PSN | (ud ? 0 : IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_MAX_QP_RD_ATOMIC)));
    if (ud) CHK(ah = ibv_create_ah(pd, &ha));
  }
  void post_recv(const int* s, int k) {
    ibv_sge g[BATCH]; ibv_recv_wr w[BATCH], *bad;
    for (int i = 0; i < k; i++) { g[i] = {(u64)(buf + (size_t)s[i] * slot), (u32)(n + (ud ? GRH : 0)), mr->lkey}; w[i] = {}; w[i].wr_id = s[i]; w[i].sg_list = &g[i]; w[i].num_sge = 1; w[i].next = i + 1 < k ? &w[i + 1] : nullptr; }
    CHK(!ibv_post_recv(qp, w, &bad));
  }
  void rx_loop(Stat& st, std::atomic<bool>& stop, u64 delay) {
    ibv_wc wc[BATCH]; int s[BATCH];
    while (true) {
      bool last = stop.load(std::memory_order_relaxed); int k = ibv_poll_cq(cq, BATCH, wc); CHK(k >= 0);
      if (!k) { if (last) return; _mm_pause(); continue; }
      for (int i = 0; i < k; i++) { if (wc[i].status) die("recv %s", ibv_wc_status_str(wc[i].status)); s[i] = wc[i].wr_id; int o = ud ? GRH : 0; check(st, buf + (size_t)s[i] * slot + o, (int)wc[i].byte_len - o, n); spin_ns(delay); }
      post_recv(s, k);
    }
  }
  u64 tx_loop(u64 end) {
    u64 posted = 0, done = 0; ibv_sge g[BATCH]; ibv_send_wr w[BATCH], *bad; ibv_wc wc[8]; bool run = true;
    while (run || done < posted) {
      if (now() >= end) run = false;
      while (run && posted - done + BATCH <= (u64)DEPTH) {
        for (int i = 0; i < BATCH; i++) {
          u8* p = buf + (size_t)((posted + i) % DEPTH) * slot; stamp(p, n, posted + i + 1);
          g[i] = {(u64)p, (u32)n, mr->lkey}; w[i] = {}; w[i].sg_list = &g[i]; w[i].num_sge = 1; w[i].opcode = IBV_WR_SEND; w[i].next = i + 1 < BATCH ? &w[i + 1] : nullptr;
          w[i].send_flags = (i + 1 == BATCH ? IBV_SEND_SIGNALED : 0) | ((u32)n <= inl ? IBV_SEND_INLINE : 0);
          if (ud) { w[i].wr.ud.ah = ah; w[i].wr.ud.remote_qpn = rq; w[i].wr.ud.remote_qkey = 0x1234; }
        }
        CHK(!ibv_post_send(qp, w, &bad)); posted += BATCH; if (now() >= end) run = false;
      }
      int k = ibv_poll_cq(cq, 8, wc); CHK(k >= 0); for (int i = 0; i < k; i++) { if (wc[i].status) die("send %s", ibv_wc_status_str(wc[i].status)); done += BATCH; }
    }
    return posted;
  }
  ~Qp() { if (ah) ibv_destroy_ah(ah); if (qp) ibv_destroy_qp(qp); if (cq) ibv_destroy_cq(cq); if (mr) ibv_dereg_mr(mr); if (pd) ibv_dealloc_pd(pd); if (ctx) ibv_close_device(ctx); if (buf) munmap(buf, (size_t)slot * DEPTH); }
};

static bool env_gro() { const char* e = getenv("FLOOD_GRO"); return e && *e == '1'; }
static void pin(int i) {                     // FLOOD_PIN="6,7,8,9": cpu for flow i
  const char* e = getenv("FLOOD_PIN"); if (!e || !*e) return; std::vector<int> v; std::string t(e); for (char* p = strtok(&t[0], ","); p; p = strtok(0, ",")) v.push_back(atoi(p));
  cpu_set_t c; CPU_ZERO(&c); CPU_SET(v[i % v.size()], &c); CHK(!pthread_setaffinity_np(pthread_self(), sizeof c, &c));
}
static void udp_rx(int fd, Stat& st, std::atomic<bool>& stop, int n, u64 delay) {
  bool gro = env_gro(); const int B = gro ? 16 : 64, SZ = gro ? 65536 : 9000; std::vector<u8> b((size_t)B * SZ); std::vector<mmsghdr> m(B); std::vector<iovec> io(B);
  struct alignas(8) Ctl { char c[64]; }; std::vector<Ctl> ct(B);
  if (gro) { int one = 1; CHK(!setsockopt(fd, SOL_UDP, UDP_GRO, &one, sizeof one)); }
  for (int i = 0; i < B; i++) { io[i] = {b.data() + (size_t)i * SZ, (size_t)SZ}; m[i].msg_hdr.msg_iov = &io[i]; m[i].msg_hdr.msg_iovlen = 1; }
  while (true) {
    bool last = stop.load(std::memory_order_relaxed);
    if (gro) for (int i = 0; i < B; i++) { m[i].msg_hdr.msg_control = ct[i].c; m[i].msg_hdr.msg_controllen = sizeof ct[i].c; }
    int k = recvmmsg(fd, m.data(), B, MSG_WAITFORONE, nullptr);
    if (k <= 0) { if (last) return; continue; }
    for (int i = 0; i < k; i++) {
      int len = m[i].msg_len, seg = len; const u8* p = b.data() + (size_t)i * SZ;
      if (gro) for (cmsghdr* h = CMSG_FIRSTHDR(&m[i].msg_hdr); h; h = CMSG_NXTHDR(&m[i].msg_hdr, h)) if (h->cmsg_level == SOL_UDP && h->cmsg_type == UDP_GRO) memcpy(&seg, CMSG_DATA(h), sizeof seg);
      for (int o = 0; o < len; o += seg) { check(st, p + o, std::min(seg, len - o), n); spin_ns(delay); }
    }
  }
}
static u64 udp_tx(int fd, int n, u64 end) {
  int segs = std::min(60, 65000 / n); CHK(!setsockopt(fd, SOL_UDP, UDP_SEGMENT, &n, sizeof n)); std::vector<u8> b(segs * n, 0x5a); u64 seq = 0;
  while (now() < end) { for (int i = 0; i < segs; i++) stamp(b.data() + i * n, n, seq + i + 1); if (send(fd, b.data(), b.size(), 0) == (ssize_t)b.size()) seq += segs; else if (errno != ENOBUFS && errno != EAGAIN && errno != ECONNREFUSED) die("udp send"); }
  return seq;
}
static std::string snap(const char* ifc) {   // cumulative counters "name value;"
  std::string o, c = std::string("ethtool -S ") + ifc + " | awk '/^ *(rx_out_of_buffer|rx_discards_phy|tx_global_pause|rx_crc_errors_phy|rx_buffer_passed_thres_phy):/{gsub(\":\",\"\");printf \"%s %s;\",$1,$2}';"
    "awk '/^Udp:/&&$2~/[0-9]/{printf \"UdpRcvbufErrors %s;\",$6}' /proc/net/snmp; for f in out_of_buffer out_of_sequence packet_seq_err rnr_nak_retry_err; do echo -n \"hw_$f $(cat /sys/class/infiniband/" + std::string(DEV) + "/ports/1/hw_counters/$f);\"; done";
  FILE* p = popen(c.c_str(), "r"); CHK(p); char b[256]; while (fgets(b, sizeof b, p)) o += b; pclose(p); return o;
}
static std::string delta(const std::string& a, const std::string& b) {
  auto parse = [](const std::string& s) { std::vector<std::pair<std::string, u64>> v; size_t i = 0; while (i < s.size()) { size_t e = s.find(';', i); if (e == std::string::npos) break; char k[64]; unsigned long long x; if (sscanf(s.substr(i, e - i).c_str(), "%63s %llu", k, &x) == 2) v.push_back({k, x}); i = e + 1; } return v; };
  auto x = parse(a), y = parse(b); std::string o; for (auto& p : y) for (auto& q : x) if (p.first == q.first && p.second != q.second) o += " " + p.first + "+" + std::to_string(p.second - q.second); return o;
}
int main(int c, char** v) {
  if (c < 5) die("usage"); bool rx = !strcmp(v[1], "rx"); Cfg f{};
  if (rx) {
    int l = socket(AF_INET, SOCK_STREAM, 0), one = 1; setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, 4); auto a = sa(v[2], PORT); CHK(!bind(l, (sockaddr*)&a, sizeof a)); CHK(!listen(l, 4)); alarm(900);
    while (true) {
      int k = accept(l, 0, 0); CHK(k >= 0); std::string s = need(k); if (s == "QUIT") return 0;
      unsigned long long dl; CHK(sscanf(s.c_str(), "%7s %d %d %d %d %llu", f.mode, &f.size, &f.secs, &f.flows, &f.rcvbuf, &dl) == 6); f.delay = dl;
      bool u = !strcmp(f.mode, "udp"), ud = !strcmp(f.mode, "ud"); std::vector<Stat> st(f.flows); std::atomic<bool> stop{false}; std::vector<std::thread> th; std::vector<int> fds; std::vector<std::unique_ptr<Qp>> q;
      for (int i = 0; i < f.flows; i++) {
        if (u) { int d = socket(AF_INET, SOCK_DGRAM, 0); auto b = sa(v[3], UPORT + i); CHK(!bind(d, (sockaddr*)&b, sizeof b)); if (f.rcvbuf) CHK(!setsockopt(d, SOL_SOCKET, SO_RCVBUFFORCE, &f.rcvbuf, 4)); timeval t{0, 100000}; setsockopt(d, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t); fds.push_back(d); }
        else { q.emplace_back(new Qp); q[i]->open(ud, true, f.size); put(k, q[i]->info()); q[i]->connect(need(k)); }
      }
      std::string s0 = snap(v[4]); double c0 = cpu_s(); u64 t0 = now();
      for (int i = 0; i < f.flows; i++) th.emplace_back([&, i] { if (u) pin(i), udp_rx(fds[i], st[i], stop, f.size, f.delay); else q[i]->rx_loop(st[i], stop, f.delay); });
      put(k, "GO"); std::string done = need(k); double el = (now() - t0) / 1e9, cpu = cpu_s() - c0;
      // drain: wait until no progress for 500 ms (Stat reads are approximate here, exact after join)
      usleep(500000); if (f.delay) usleep(3000000);
      stop = true; for (auto& t : th) t.join(); for (int d : fds) close(d);
      u64 r = 0, b = 0, g = 0; for (auto& x : st) r += x.rx, b += x.bad, g += x.gaps; char o[256]; snprintf(o, sizeof o, "%llu %llu %llu %.2f", (unsigned long long)r, (unsigned long long)b, (unsigned long long)g, cpu / el);
      put(k, o + delta(s0, snap(v[4]))); close(k);
    }
  }
  CHK(c == 11 || !strcmp(v[5], "QUIT")); int k = socket(AF_INET, SOCK_STREAM, 0); auto a = sa(v[2], PORT); CHK(!connect(k, (sockaddr*)&a, sizeof a)); if (!strcmp(v[5], "QUIT")) { put(k, "QUIT"); return 0; }
  snprintf(f.mode, sizeof f.mode, "%s", v[5]); f.size = atoi(v[6]); f.secs = atoi(v[7]); f.flows = atoi(v[8]); f.rcvbuf = atoi(v[9]); f.delay = atoll(v[10]); CHK(f.size >= 16 && f.size <= 8192);
  alarm(f.secs + 60); put(k, std::string(f.mode) + " " + v[6] + " " + v[7] + " " + v[8] + " " + v[9] + " " + v[10]);
  bool u = !strcmp(f.mode, "udp"), ud = !strcmp(f.mode, "ud"); std::vector<std::unique_ptr<Qp>> q; std::vector<int> fds;
  for (int i = 0; i < f.flows; i++) {
    if (u) { int d = socket(AF_INET, SOCK_DGRAM, 0); auto b = sa(v[4], 0), p = sa(v[3], UPORT + i); CHK(!bind(d, (sockaddr*)&b, sizeof b)); CHK(!connect(d, (sockaddr*)&p, sizeof p)); fds.push_back(d); }
    else { q.emplace_back(new Qp); q[i]->open(ud, false, f.size); std::string s = need(k); put(k, q[i]->info()); q[i]->connect(s); }
  }
  CHK(need(k) == "GO"); std::vector<u64> sent(f.flows); std::vector<std::thread> th; double c0 = cpu_s(); u64 t0 = now(), end = t0 + f.secs * 1000000000ull;
  for (int i = 0; i < f.flows; i++) th.emplace_back([&, i] { sent[i] = u ? udp_tx(fds[i], f.size, end) : q[i]->tx_loop(end); });
  for (auto& t : th) t.join(); double el = (now() - t0) / 1e9, cpu = cpu_s() - c0; put(k, "DONE"); u64 tot = 0; for (u64 x : sent) tot += x;
  std::string r = need(k); unsigned long long got, bad, gaps; double rc; int at = 0; CHK(sscanf(r.c_str(), "%llu %llu %llu %lf%n", &got, &bad, &gaps, &rc, &at) == 4);
  printf("%-4s size=%-5d buf=%-9d delay=%-5llu sent=%-10llu recv=%-10llu lost=%-10lld (%6.2f%%) bad=%llu gaps=%llu | tx %.3f Mpps rx %.3f Mpps %.2f Gb/s goodput | cpu tx %.1f rx %.1f cores |%s\n", f.mode, f.size, f.rcvbuf, (unsigned long long)f.delay, (unsigned long long)tot, got, (long long)(tot - got), 100.0 * ((double)tot - got) / tot, bad, gaps, tot / el / 1e6, got / el / 1e6, got * 8.0 * f.size / el / 1e9, cpu / el, rc, r.c_str() + at);
}
