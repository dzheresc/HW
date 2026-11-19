// k7cap: 10G packet capture from the k7_cap bitstream (xc7k325t board, SFP A).
//
// The FPGA writes every frame received on SFP A into a host ring of 2 MB hugepages
// (DMA, PCIe Gen2 x4) and reports its write offset (head) in a status hugepage. This
// tool sets that up from user space (no kernel driver: sysfs BAR mmap + hugepages +
// /proc/self/pagemap, so it needs root and no IOMMU), runs a receive thread pinned to
// one core that turns ring records into pcap records (nanosecond timestamps) and hands
// filled buffers to a writer thread, and prints statistics once a second.
//
// Drops are reported from both ends: the FPGA counts frames it could not buffer
// (ring full because the host was too slow), and every record carries the number of
// frames dropped just before it, so the host total must match the FPGA counter.
//
// Build: g++ -O2 -std=c++17 -pthread -o k7cap k7cap.cpp
// Usage: sudo ./k7cap [options]       (see usage())
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <dirent.h>
#include <fcntl.h>
#include <mutex>
#include <pthread.h>
#include <sched.h>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <thread>
#include <time.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t kVendor = 0x10EE, kDevice = 0x7022;
constexpr size_t kHuge = 2u << 20;
constexpr double kTickNs = 6.4;   // nominal 156.25 MHz timestamp clock
// ns per tick, measured against CLOCK_REALTIME once a second (the board refclk is a few ppm off)
std::atomic<double> g_tickNs{kTickNs};

// BAR0 registers (cap_top.v)
enum : uint32_t {
  R_ID = 0x000, R_VER = 0x004, R_ETH = 0x020,
  C_CTRL = 0x100, C_STATUS = 0x104, C_SNAP = 0x108, C_BLKCFG = 0x10C, C_TBL_IDX = 0x110,
  C_TBL_LO = 0x114, C_TBL_HI = 0x118, C_TIMEOUT = 0x11C, C_STAT_LO = 0x120, C_STAT_HI = 0x124,
  C_STAT_THR = 0x128, C_TAIL = 0x12C, C_HEAD = 0x130, C_TS = 0x138, C_TG_CFG = 0x140,
  C_FIFO_MAX = 0x144, C_RX_FRAMES = 0x150, C_RX_BYTES = 0x158, C_CAP_FRAMES = 0x160,
  C_DROP_FRAMES = 0x168, C_BAD_FRAMES = 0x170, C_RECORDS = 0x178, C_TLPS = 0x180,
  C_STALLS = 0x188, C_TG_SEQ = 0x190,
};
enum : uint32_t { CTRL_EN = 1, CTRL_RESET = 2, CTRL_KEEP_BAD = 4, CTRL_KEEP_FCS = 8, CTRL_TG = 16 };
enum : uint8_t { F_BAD = 1, F_TRUNC = 2, F_FCS = 4, F_ABORT = 8 };

[[noreturn]] void die(const std::string& m) {
  throw std::runtime_error(m + (errno ? std::string(": ") + std::strerror(errno) : ""));
}

std::string readLine(const std::string& p) {
  FILE* f = std::fopen(p.c_str(), "r");
  if (!f) return "";
  char buf[256] = {0};
  if (!std::fgets(buf, sizeof buf, f)) buf[0] = 0;
  std::fclose(f);
  return buf;
}

std::string findDevice() {
  DIR* d = opendir("/sys/bus/pci/devices");
  if (!d) die("cannot open /sys/bus/pci/devices");
  std::string found;
  while (dirent* e = readdir(d)) {
    if (e->d_name[0] == '.') continue;
    std::string b = std::string("/sys/bus/pci/devices/") + e->d_name;
    if (std::strtoul(readLine(b + "/vendor").c_str(), nullptr, 16) == kVendor &&
        std::strtoul(readLine(b + "/device").c_str(), nullptr, 16) == kDevice) {
      found = e->d_name;
      break;
    }
  }
  closedir(d);
  errno = 0;
  if (found.empty()) die("no 10ee:7022 device (load the k7_cap bitstream, then rescan the PCI bus)");
  return found;
}

class Bar {
 public:
  explicit Bar(const std::string& bdf) {
    std::string base = "/sys/bus/pci/devices/" + bdf;
    // memory decoding + bus mastering in the command register (no driver is bound)
    int cfg = open((base + "/config").c_str(), O_RDWR);
    if (cfg < 0) die("open " + base + "/config");
    uint16_t cmd = 0;
    if (pread(cfg, &cmd, 2, 4) != 2) die("read command register");
    cmd |= 0x0006;
    if (pwrite(cfg, &cmd, 2, 4) != 2) die("write command register");
    close(cfg);
    fd_ = open((base + "/resource0").c_str(), O_RDWR | O_SYNC);
    if (fd_ < 0) die("open " + base + "/resource0");
    void* p = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
    if (p == MAP_FAILED) die("mmap BAR0");
    m_ = static_cast<volatile uint32_t*>(p);
  }
  ~Bar() { munmap(const_cast<uint32_t*>(m_), 4096); close(fd_); }
  uint32_t rd(uint32_t off) const { return m_[off / 4]; }
  void wr(uint32_t off, uint32_t v) const { m_[off / 4] = v; }
  uint64_t rd64(uint32_t off) const {   // lo latches hi
    uint64_t lo = rd(off);
    return lo | (uint64_t(rd(off + 4)) << 32);
  }

 private:
  int fd_ = -1;
  volatile uint32_t* m_ = nullptr;
};

uint64_t physOf(const void* v) {
  static int fd = open("/proc/self/pagemap", O_RDONLY);
  if (fd < 0) die("open /proc/self/pagemap");
  uint64_t va = reinterpret_cast<uint64_t>(v), ent = 0;
  if (pread(fd, &ent, 8, (va / 4096) * 8) != 8) die("read pagemap");
  if (!(ent >> 63) || (ent & ((1ull << 55) - 1)) == 0) {
    errno = 0;
    die("pagemap gives no physical address (run as root)");
  }
  return (ent & ((1ull << 55) - 1)) * 4096 + (va & 4095);
}

// N + 1 hugepages: N for the ring (virtually contiguous), the last one for status.
struct DmaMem {
  uint8_t* base = nullptr;
  size_t pages = 0;
  std::vector<uint64_t> phys;
  explicit DmaMem(size_t n) : pages(n + 1) {
    size_t need = pages;
    long have = std::strtol(readLine("/proc/sys/vm/nr_hugepages").c_str(), nullptr, 10);
    long freeP = std::strtol(readLine("/sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages").c_str(), nullptr, 10);
    if (freeP < long(need)) {
      if (FILE* f = std::fopen("/proc/sys/vm/nr_hugepages", "w")) {
        std::fprintf(f, "%ld\n", have + long(need) - freeP);
        std::fclose(f);
      }
    }
    void* p = mmap(nullptr, pages * kHuge, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE | MAP_LOCKED, -1, 0);
    if (p == MAP_FAILED) die("mmap " + std::to_string(pages) + " x 2 MB hugepages (see /proc/meminfo)");
    base = static_cast<uint8_t*>(p);
    std::memset(base, 0, pages * kHuge);
    for (size_t i = 0; i < pages; ++i) {
      phys.push_back(physOf(base + i * kHuge));
      if (physOf(base + i * kHuge + kHuge - 4096) != phys.back() + kHuge - 4096) {
        errno = 0;
        die("hugepage not physically contiguous");
      }
    }
  }
  ~DmaMem() { if (base) munmap(base, pages * kHuge); }
};

// ---------------- pcap output ----------------
struct Chunk {
  std::vector<uint8_t> buf;
  size_t len = 0;
};

class Writer {
 public:
  Writer(const std::string& path, size_t nchunks, size_t chunk) : chunk_(chunk) {
    if (!path.empty()) {
      fd_ = (path == "-") ? 1 : open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (fd_ < 0) die("open " + path);
    }
    for (size_t i = 0; i < nchunks; ++i) {
      auto* c = new Chunk;
      c->buf.resize(chunk);
      free_.push_back(c);
    }
    th_ = std::thread([this] { run(); });
  }
  ~Writer() {
    {
      std::lock_guard<std::mutex> l(mu_);
      stop_ = true;
    }
    cv_.notify_all();
    th_.join();
    for (auto* c : free_) delete c;
    if (fd_ > 1) close(fd_);
  }
  bool enabled() const { return fd_ >= 0; }
  size_t chunkSize() const { return chunk_; }
  // receive thread: a free chunk, or nullptr if all are queued (caller retries)
  Chunk* get() {
    std::lock_guard<std::mutex> l(mu_);
    if (free_.empty()) return nullptr;
    Chunk* c = free_.back();
    free_.pop_back();
    c->len = 0;
    return c;
  }
  void put(Chunk* c) {
    {
      std::lock_guard<std::mutex> l(mu_);
      full_.push_back(c);
    }
    cv_.notify_all();
  }
  void writeRaw(const void* p, size_t n) {
    if (fd_ >= 0 && ::write(fd_, p, n) != ssize_t(n)) die("write");
  }
  uint64_t written() const { return written_.load(std::memory_order_relaxed); }
  void drain() {   // wait until every queued chunk is on disk
    std::unique_lock<std::mutex> l(mu_);
    cv_.wait(l, [this] { return full_.empty() && !busy_; });
  }
  size_t backlog() {
    std::lock_guard<std::mutex> l(mu_);
    return full_.size();
  }

 private:
  void run() {
    for (;;) {
      Chunk* c;
      {
        std::unique_lock<std::mutex> l(mu_);
        cv_.wait(l, [this] { return stop_ || !full_.empty(); });
        if (full_.empty()) return;
        c = full_.front();
        full_.pop_front();
        busy_ = true;
      }
      size_t off = 0;
      while (fd_ >= 0 && off < c->len) {
        ssize_t n = ::write(fd_, c->buf.data() + off, c->len - off);
        if (n <= 0) { std::perror("pcap write"); break; }
        off += size_t(n);
      }
      written_ += c->len;
      {
        std::lock_guard<std::mutex> l(mu_);
        free_.push_back(c);
        busy_ = false;
      }
      cv_.notify_all();
    }
  }
  int fd_ = -1;
  size_t chunk_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::vector<Chunk*> free_;
  std::deque<Chunk*> full_;
  bool stop_ = false, busy_ = false;
  std::atomic<uint64_t> written_{0};
  std::thread th_;
};

// ---------------- options ----------------
struct Opts {
  std::string bdf, out;
  int core = 3;
  uint32_t snap = 9600;
  size_t ringMb = 256;
  uint64_t count = 0;
  double seconds = 0;
  bool keepBad = false, keepFcs = false, quiet = false;
  bool tg = false, check = false;
  uint32_t tgLen = 60, tgGap = 3;
};

void usage() {
  std::fprintf(stderr,
    "usage: k7cap [options]\n"
    "  -w FILE        write pcap (nanosecond timestamps) to FILE, '-' = stdout\n"
    "  -c CORE        pin the receive thread to CORE (default 3)\n"
    "  -s SNAPLEN     bytes kept per frame (64..16384, multiple of 8, default 9600)\n"
    "  -m MB          ring size in MB (2 MB hugepages, default 256, max 1024)\n"
    "  -n COUNT       stop after COUNT records\n"
    "  -t SECONDS     stop after SECONDS\n"
    "  -i BDF         PCI device (default: find 10ee:7022)\n"
    "  --keep-bad     also capture frames with FCS / framing errors\n"
    "  --keep-fcs     keep the 4 FCS bytes in the captured data\n"
    "  --testgen L,G  internal generator instead of SFP A: L-byte frames, G idle cycles\n"
    "                 (6.4 ns) after each (60,3 = line rate); nothing is sent on the wire\n"
    "  --check        with --testgen: verify the sequence numbers (gaps must equal drops)\n"
    "  -q             no per-second statistics\n");
}

Opts parse(int argc, char** argv) {
  Opts o;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) { usage(); std::exit(2); }
      return argv[++i];
    };
    if (a == "-w") o.out = next();
    else if (a == "-c") o.core = std::stoi(next());
    else if (a == "-s") o.snap = std::stoul(next());
    else if (a == "-m") o.ringMb = std::stoul(next());
    else if (a == "-n") o.count = std::stoull(next());
    else if (a == "-t") o.seconds = std::stod(next());
    else if (a == "-i") o.bdf = next();
    else if (a == "--keep-bad") o.keepBad = true;
    else if (a == "--keep-fcs") o.keepFcs = true;
    else if (a == "--check") o.check = true;
    else if (a == "-q") o.quiet = true;
    else if (a == "--testgen") {
      std::string v = next();
      o.tg = true;
      std::sscanf(v.c_str(), "%u,%u", &o.tgLen, &o.tgGap);
    } else { usage(); std::exit(2); }
  }
  if (o.ringMb < 4) o.ringMb = 4;
  if (o.ringMb > 1024) o.ringMb = 1024;
  o.ringMb &= ~size_t(1);
  o.snap = std::max<uint32_t>(64, std::min<uint32_t>(16384, o.snap & ~7u));
  return o;
}

std::atomic<bool> g_stop{false};
void onSignal(int) { g_stop = true; }

// ---------------- receive thread ----------------
struct RxStats {
  std::atomic<uint64_t> records{0}, bytes{0}, wireBytes{0}, drops{0}, bad{0}, trunc{0};
  std::atomic<uint64_t> seqErrors{0}, chunkWaits{0}, tail{0};
};

struct Rx {
  const Opts& o;
  const Bar& bar;
  DmaMem& mem;
  Writer& w;
  RxStats& st;
  uint64_t ringSize;
  uint64_t ts0;          // FPGA ticks at t0
  int64_t t0ns;          // CLOCK_REALTIME at ts0
  std::atomic<bool> done{false};
  uint64_t nextSeq = 0;
  bool haveSeq = false;

  volatile uint64_t* statHead() const {
    return reinterpret_cast<volatile uint64_t*>(mem.base + (mem.pages - 1) * kHuge);
  }
  void copyOut(uint8_t* dst, uint64_t off, size_t n) const {
    uint64_t p = off % ringSize;
    size_t first = std::min<uint64_t>(n, ringSize - p);
    std::memcpy(dst, mem.base + p, first);
    if (first < n) std::memcpy(dst + first, mem.base, n - first);
  }

  void run() {
    if (o.core >= 0) {
      cpu_set_t s;
      CPU_ZERO(&s);
      CPU_SET(o.core, &s);
      if (pthread_setaffinity_np(pthread_self(), sizeof s, &s) != 0)
        std::fprintf(stderr, "warning: cannot pin to core %d\n", o.core);
    }
    uint64_t tail = 0, lastTailWr = 0;
    Chunk* c = nullptr;
    uint8_t hdr[16];
    for (;;) {
      uint64_t head = *statHead();
      uint64_t again = *statHead();
      if (again != head) continue;            // torn 8-byte read (DMA in progress)
      std::atomic_thread_fence(std::memory_order_acquire);
      bool progressed = false;
      while (head - tail >= 16) {
        copyOut(hdr, tail, 16);
        uint64_t ts, w1;
        std::memcpy(&ts, hdr, 8);
        std::memcpy(&w1, hdr + 8, 8);
        uint32_t clen = w1 & 0xFFFF, wlen = (w1 >> 16) & 0xFFFF;
        uint8_t flags = (w1 >> 32) & 0xFF;
        uint32_t drops = (w1 >> 48) & 0xFFFF;
        uint64_t rlen = 16 + ((uint64_t(clen) + 7) & ~7ull);
        if (head - tail < rlen) break;        // rest of the record not reported yet
        if (w.enabled()) {
          if (!c || c->len + 16 + clen > c->buf.size()) {
            if (c) w.put(c);
            while (!(c = w.get())) {           // writer behind: ring fills, FPGA drops
              st.chunkWaits++;
              std::this_thread::sleep_for(std::chrono::microseconds(50));
            }
          }
          int64_t ns = t0ns + int64_t(double(ts - ts0) * g_tickNs.load(std::memory_order_relaxed));
          uint32_t ph[4] = {uint32_t(ns / 1000000000), uint32_t(ns % 1000000000), clen, wlen};
          std::memcpy(c->buf.data() + c->len, ph, 16);
          copyOut(c->buf.data() + c->len + 16, tail + 16, clen);
          c->len += 16 + clen;
        }
        if (o.check && clen >= 24) {
          uint64_t seq;
          copyOut(reinterpret_cast<uint8_t*>(&seq), tail + 16 + 16, 8);
          if (haveSeq && seq != nextSeq + drops) st.seqErrors++;
          nextSeq = seq + 1;
          haveSeq = true;
        }
        st.records.fetch_add(1, std::memory_order_relaxed);
        st.bytes.fetch_add(clen, std::memory_order_relaxed);
        st.wireBytes.fetch_add(wlen, std::memory_order_relaxed);
        if (drops) st.drops.fetch_add(drops, std::memory_order_relaxed);
        if (flags & F_BAD) st.bad.fetch_add(1, std::memory_order_relaxed);
        if (flags & F_TRUNC) st.trunc.fetch_add(1, std::memory_order_relaxed);
        tail += rlen;
        progressed = true;
        if (tail - lastTailWr >= ringSize / 8) {   // return space early on long bursts
          bar.wr(C_TAIL, uint32_t(tail));
          lastTailWr = tail;
        }
        if (o.count && st.records.load(std::memory_order_relaxed) >= o.count) g_stop = true;
      }
      if (progressed && tail != lastTailWr) {
        bar.wr(C_TAIL, uint32_t(tail));
        lastTailWr = tail;
      }
      st.tail.store(tail, std::memory_order_relaxed);
      if (!progressed) {
        if (done.load(std::memory_order_acquire)) break;
        _mm_pause_like();
      }
    }
    if (c) {
      if (c->len) w.put(c);
      else w.put(c);  // empty chunk: writer returns it to the pool
    }
  }
  static void _mm_pause_like() { asm volatile("pause" ::: "memory"); }
};

int64_t nowNs() {
  timespec t;
  clock_gettime(CLOCK_REALTIME, &t);
  return int64_t(t.tv_sec) * 1000000000 + t.tv_nsec;
}

void printFpga(const Bar& bar, FILE* f) {
  std::fprintf(f,
    "fpga: rx_frames %llu rx_bytes %llu captured %llu dropped %llu bad %llu records %llu tlps %llu "
    "ring_full_stalls %llu fifo_max %u/32768 words\n",
    (unsigned long long)bar.rd64(C_RX_FRAMES), (unsigned long long)bar.rd64(C_RX_BYTES),
    (unsigned long long)bar.rd64(C_CAP_FRAMES), (unsigned long long)bar.rd64(C_DROP_FRAMES),
    (unsigned long long)bar.rd64(C_BAD_FRAMES), (unsigned long long)bar.rd64(C_RECORDS),
    (unsigned long long)bar.rd64(C_TLPS), (unsigned long long)bar.rd64(C_STALLS),
    bar.rd(C_FIFO_MAX));
}

}  // namespace

int main(int argc, char** argv) {
  try {
    Opts o = parse(argc, argv);
    std::string bdf = o.bdf.empty() ? findDevice() : o.bdf;
    Bar bar(bdf);
    if (bar.rd(R_ID) != 0x4B375043 || bar.rd(R_VER) < 0x00040000) {
      errno = 0;
      die("unexpected ID/VERSION (not the k7_cap bitstream?)");
    }
    FILE* info = (o.out == "-") ? stderr : stdout;

    size_t nblk = o.ringMb / 2;
    DmaMem mem(nblk);
    uint64_t ringSize = uint64_t(nblk) * kHuge;

    // ---- program the capture engine ----
    uint32_t flags = (o.keepBad ? CTRL_KEEP_BAD : 0) | (o.keepFcs ? CTRL_KEEP_FCS : 0) | (o.tg ? CTRL_TG : 0);
    bar.wr(C_CTRL, CTRL_RESET);
    usleep(1000);
    bar.wr(C_SNAP, o.snap);
    bar.wr(C_BLKCFG, (uint32_t(nblk) << 16) | 21);
    bar.wr(C_TBL_IDX, 0);
    for (size_t i = 0; i < nblk; ++i) {
      bar.wr(C_TBL_LO, uint32_t(mem.phys[i]));
      bar.wr(C_TBL_HI, uint32_t(mem.phys[i] >> 32));
    }
    uint64_t stat = mem.phys[nblk];
    bar.wr(C_STAT_LO, uint32_t(stat));
    bar.wr(C_STAT_HI, uint32_t(stat >> 32));
    bar.wr(C_STAT_THR, 32768);
    bar.wr(C_TIMEOUT, 500);           // 2 us (4 ns units)
    bar.wr(C_TAIL, 0);
    bar.wr(C_TG_CFG, (o.tgGap << 16) | (o.tgLen & 0xFFFF));
    bar.wr(C_CTRL, flags);            // out of reset, not yet enabled
    usleep(1000);
    uint32_t status = bar.rd(C_STATUS);
    if (!(status & 1)) { errno = 0; die("bus mastering is off"); }
    uint32_t eth = bar.rd(R_ETH);
    std::fprintf(info, "k7cap: device %s, MPS %u, SFP A %s, ring %zu MB (%zu hugepages), snaplen %u%s%s%s\n",
                 bdf.c_str(), 128u << ((status >> 2) & 7), (eth >> 16) & 1 ? "block lock" : "NO LOCK",
                 o.ringMb, nblk, o.snap, o.keepBad ? ", keep bad" : "", o.keepFcs ? ", keep FCS" : "",
                 o.tg ? ", TEST GENERATOR" : "");

    // timestamp anchor: FPGA ticks vs CLOCK_REALTIME (midpoint of the MMIO read)
    int64_t a = nowNs();
    uint64_t ts0 = bar.rd64(C_TS);
    int64_t b = nowNs();
    int64_t t0ns = a + (b - a) / 2;

    Writer w(o.out, 64, 4u << 20);
    if (w.enabled()) {
      uint32_t gh[6] = {0xa1b23c4d, 0x00040002, 0, 0, o.snap, 1};   // pcap, ns, Ethernet
      w.writeRaw(gh, sizeof gh);
    }
    RxStats st;
    Rx rx{o, bar, mem, w, st, ringSize, ts0, t0ns};
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    std::thread rxThread([&] { rx.run(); });

    bar.wr(C_CTRL, flags | CTRL_EN);
    auto start = std::chrono::steady_clock::now();
    auto last = start;
    uint64_t lastRec = 0, lastBytes = 0, lastWire = 0;
    while (!g_stop) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      auto now = std::chrono::steady_clock::now();
      double el = std::chrono::duration<double>(now - start).count();
      if (o.seconds > 0 && el >= o.seconds) break;
      double dt = std::chrono::duration<double>(now - last).count();
      if (dt >= 1.0) {
        int64_t a1 = nowNs();
        uint64_t tsn = bar.rd64(C_TS);
        int64_t b1 = nowNs();
        if (tsn - ts0 > 100000000) g_tickNs = double(a1 + (b1 - a1) / 2 - t0ns) / double(tsn - ts0);
        uint64_t r = st.records, by = st.bytes, wb = st.wireBytes;
        uint64_t head = bar.rd64(C_HEAD);
        if (!o.quiet)
          std::fprintf(info, "%6.0fs  %9.0f pkt/s %7.3f Gbit/s (wire %7.3f)  recs %llu drops %llu (fpga %llu) bad %llu  ring %4.1f%%  backlog %zu\n",
                       el, (r - lastRec) / dt, (by - lastBytes) * 8e-9 / dt, (wb - lastWire) * 8e-9 / dt,
                       (unsigned long long)r, (unsigned long long)st.drops.load(),
                       (unsigned long long)bar.rd64(C_DROP_FRAMES), (unsigned long long)st.bad.load(),
                       100.0 * double(head - st.tail.load()) / double(ringSize), w.backlog());
        lastRec = r; lastBytes = by; lastWire = wb; last = now;
      }
    }

    // ---- stop: no new frames, drain what the FPGA has buffered ----
    bar.wr(C_CTRL, flags);
    uint64_t prev = ~0ull;
    for (int i = 0; i < 200; ++i) {                 // up to 2 s
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      uint64_t h = bar.rd64(C_HEAD);
      if (h == prev && st.tail.load() == h && bar.rd64(C_RECORDS) == bar.rd64(C_CAP_FRAMES)) break;
      prev = h;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));   // counter snapshots (105 us)
    rx.done = true;
    rxThread.join();
    w.drain();

    uint64_t fCap = bar.rd64(C_CAP_FRAMES), fDrop = bar.rd64(C_DROP_FRAMES);
    std::fprintf(info, "host: records %llu bytes %llu (wire %llu) drops-in-records %llu bad %llu truncated %llu "
                       "writer-waits %llu pcap-bytes %llu\n",
                 (unsigned long long)st.records.load(), (unsigned long long)st.bytes.load(),
                 (unsigned long long)st.wireBytes.load(), (unsigned long long)st.drops.load(),
                 (unsigned long long)st.bad.load(), (unsigned long long)st.trunc.load(),
                 (unsigned long long)st.chunkWaits.load(), (unsigned long long)(w.written() + (w.enabled() ? 24 : 0)));
    printFpga(bar, info);
    if (o.tg) std::fprintf(info, "testgen: generated %llu, sequence errors %llu\n",
                           (unsigned long long)bar.rd64(C_TG_SEQ), (unsigned long long)st.seqErrors.load());
    bool ok = st.records.load() == fCap;
    std::fprintf(info, "%s: host records %s FPGA captured; FPGA dropped %llu (%llu reported inside records, the rest after the last record)\n",
                 ok ? "OK" : "MISMATCH", ok ? "==" : "!=", (unsigned long long)fDrop,
                 (unsigned long long)st.drops.load());
    bar.wr(C_CTRL, CTRL_RESET);
    return ok && st.seqErrors.load() == 0 ? 0 : 1;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "k7cap: %s\n", e.what());
    return 1;
  }
}
