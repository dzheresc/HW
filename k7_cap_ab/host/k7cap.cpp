// k7cap: 10G packet capture from the k7_cap_ab bitstream (xc7k325t board, SFP A and/or B).
//
// The FPGA writes every frame received on the selected SFP cages into one host ring of
// 2 MB hugepages (DMA, PCIe Gen2 x4) and reports its write offset (head) in a status
// hugepage. Each record says which cage it came from (header byte 13). This tool sets
// that up from user space (no kernel driver: sysfs BAR mmap + hugepages +
// /proc/self/pagemap, so it needs root and no IOMMU), runs a receive thread pinned to
// one core that turns ring records into pcap or pcapng records (nanosecond timestamps)
// and hands filled buffers to a writer thread, and prints statistics once a second.
//
// Output: FILE.pcapng = pcapng with one interface per cage (sfp_a = 0, sfp_b = 1), drops
// before a packet in epb_dropcount, bad FCS in epb_flags, if_fcslen 4 with --keep-fcs.
// Any other name = classic pcap, which has no port field: only with one port (-p a / -p b).
//
// Drops are reported from both ends, per port: the FPGA counts frames it could not
// buffer (ring full because the host was too slow, or more than PCIe x4 carries), and
// every record carries the number of frames dropped on its port just before it, so the
// host totals must match the FPGA counters.
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
  C_FIFO_MAX = 0x144, C_PORTS = 0x148, C_RECORDS = 0x178, C_TLPS = 0x180, C_STALLS = 0x188,
};
// per-port 64-bit counters: port A at 0x150.. (TG_SEQ 0x190), port B at 0x1A0.. (TG_SEQ 0x1C8)
constexpr uint32_t kRxFrames[2] = {0x150, 0x1A0}, kRxBytes[2] = {0x158, 0x1A8},
                   kCapFrames[2] = {0x160, 0x1B0}, kDropFrames[2] = {0x168, 0x1B8},
                   kBadFrames[2] = {0x170, 0x1C0}, kTgSeq[2] = {0x190, 0x1C8};
constexpr const char* kPortName[2] = {"A", "B"};
enum : uint32_t { CTRL_EN = 1, CTRL_RESET = 2, CTRL_KEEP_BAD = 4, CTRL_KEEP_FCS = 8, CTRL_TG = 16 };
enum : uint8_t { F_BAD = 1, F_TRUNC = 2, F_FCS = 4, F_ABORT = 8 };

[[noreturn]] void die(const std::string& m) {
  throw std::runtime_error(m + (errno ? std::string(": ") + std::strerror(errno) : ""));
}

// Where the drops not carried by records went: after the last record, or above the 65535
// that a record's drop field holds (it saturates).
std::string cappedNote(uint64_t capped) {
  if (!capped) return "after the last record";
  return "after the last record or beyond the 65535 cap in " + std::to_string(capped) + " records";
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
  if (found.empty()) die("no 10ee:7022 device (load the k7_cap_ab bitstream, then rescan the PCI bus)");
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
  unsigned ports = 3;     // bit 0 = SFP A, bit 1 = SFP B
  bool pcapng = false;
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
    "  -p a|b|ab      SFP cages to capture (default ab)\n"
    "  -w FILE        write FILE.pcapng (pcapng, one interface per cage) or any other name as\n"
    "                 classic pcap (one port only); nanosecond timestamps; '-' = pcapng to stdout\n"
    "  -c CORE        pin the receive thread to CORE (default 3)\n"
    "  -s SNAPLEN     bytes kept per frame (64..16384, multiple of 8, default 9600)\n"
    "  -m MB          ring size in MB (2 MB hugepages, default 256, max 1024)\n"
    "  -n COUNT       stop after COUNT records\n"
    "  -t SECONDS     stop after SECONDS\n"
    "  -i BDF         PCI device (default: find 10ee:7022)\n"
    "  --keep-bad     also capture frames with FCS / framing errors\n"
    "  --keep-fcs     keep the 4 FCS bytes in the captured data\n"
    "  --testgen L,G  internal generators instead of the cages (one per selected port):\n"
    "                 L-byte frames, G idle cycles (6.4 ns) after each (60,3 = line rate);\n"
    "                 nothing is sent on the wire\n"
    "  --check        with --testgen: verify each port's sequence numbers (gaps must equal drops)\n"
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
    else if (a == "-p") {
      std::string v = next();
      o.ports = (v == "a") ? 1 : (v == "b") ? 2 : (v == "ab" || v == "ba") ? 3 : 0;
      if (!o.ports) { usage(); std::exit(2); }
    }
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
  o.pcapng = o.out == "-" ||
             (o.out.size() > 7 && o.out.compare(o.out.size() - 7, 7, ".pcapng") == 0);
  if (!o.out.empty() && !o.pcapng && o.ports == 3) {
    std::fprintf(stderr, "k7cap: classic pcap has no port field: use -w FILE.pcapng, or -p a / -p b\n");
    std::exit(2);
  }
  return o;
}

std::atomic<bool> g_stop{false};
void onSignal(int) { g_stop = true; }

// ---------------- receive thread ----------------
struct PortStats {
  std::atomic<uint64_t> records{0}, bytes{0}, wireBytes{0}, drops{0}, dropsCapped{0}, bad{0}, trunc{0};
};
struct RxStats {
  PortStats p[2];
  std::atomic<uint64_t> records{0}, badPort{0}, seqErrors{0}, seqSaturated{0}, chunkWaits{0}, tail{0};
};

// pcapng blocks (little endian, host order on x86)
void put32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 0; i < 4; ++i) v.push_back(uint8_t(x >> (8 * i))); }
void put16(std::vector<uint8_t>& v, uint16_t x) { v.push_back(uint8_t(x)); v.push_back(uint8_t(x >> 8)); }
void putOpt(std::vector<uint8_t>& v, uint16_t code, const void* p, uint16_t n) {
  put16(v, code); put16(v, n);
  const uint8_t* b = static_cast<const uint8_t*>(p);
  v.insert(v.end(), b, b + n);
  while (v.size() % 4) v.push_back(0);
}
std::vector<uint8_t> pcapngHeader(uint32_t snap, bool keepFcs) {
  std::vector<uint8_t> v;
  put32(v, 0x0A0D0D0A); put32(v, 28); put32(v, 0x1A2B3C4D); put16(v, 1); put16(v, 0);
  put32(v, 0xFFFFFFFF); put32(v, 0xFFFFFFFF); put32(v, 28);                      // SHB
  for (int p = 0; p < 2; ++p) {                                                  // IDB per cage
    std::vector<uint8_t> b;
    put32(b, 1); put32(b, 0); put16(b, 1); put16(b, 0); put32(b, snap);         // Ethernet
    std::string name = p ? "sfp_b" : "sfp_a";
    std::string desc = p ? "xc7k325t card SFP B (k7_cap_ab)" : "xc7k325t card SFP A (k7_cap_ab)";
    uint8_t tsres = 9, fcslen = keepFcs ? 4 : 0;
    putOpt(b, 2, name.data(), uint16_t(name.size()));
    putOpt(b, 3, desc.data(), uint16_t(desc.size()));
    putOpt(b, 9, &tsres, 1);
    putOpt(b, 13, &fcslen, 1);
    put32(b, 0);                                                                 // opt_endofopt
    put32(b, uint32_t(b.size() + 4));
    uint32_t len = uint32_t(b.size());
    std::memcpy(b.data() + 4, &len, 4);
    v.insert(v.end(), b.begin(), b.end());
  }
  return v;
}

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
  uint64_t nextSeq[2] = {0, 0};
  bool haveSeq[2] = {false, false};

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
        unsigned port = (w1 >> 40) & 0xFF;
        uint32_t drops = (w1 >> 48) & 0xFFFF;
        uint64_t rlen = 16 + ((uint64_t(clen) + 7) & ~7ull);
        if (head - tail < rlen) break;        // rest of the record not reported yet
        if (port > 1) { st.badPort++; port = 1; }
        if (w.enabled()) {
          // pcapng EPB: 28 header + data padded to 4 + options (flags 8, dropcount 12, end 4) + 4
          size_t need = o.pcapng ? 28 + ((clen + 3) & ~3u) + 24 + 4 : 16 + clen;
          if (!c || c->len + need > c->buf.size()) {
            if (c) w.put(c);
            while (!(c = w.get())) {           // writer behind: ring fills, FPGA drops
              st.chunkWaits++;
              std::this_thread::sleep_for(std::chrono::microseconds(50));
            }
          }
          int64_t ns = t0ns + int64_t(double(ts - ts0) * g_tickNs.load(std::memory_order_relaxed));
          uint8_t* d = c->buf.data() + c->len;
          if (o.pcapng) {
            uint32_t pad = (clen + 3) & ~3u;
            bool optFlags = flags & F_BAD, optDrop = drops != 0;
            uint32_t total = 28 + pad + (optFlags ? 8 : 0) + (optDrop ? 12 : 0) +
                             ((optFlags || optDrop) ? 4 : 0) + 4;
            uint32_t eh[7] = {6, total, port, uint32_t(uint64_t(ns) >> 32), uint32_t(ns), clen, wlen};
            std::memcpy(d, eh, 28);
            copyOut(d + 28, tail + 16, clen);
            std::memset(d + 28 + clen, 0, pad - clen);
            uint8_t* q = d + 28 + pad;
            if (optFlags) {                    // epb_flags: inbound, CRC error
              uint32_t oh = 2 | (4u << 16), fv = 1u | (1u << 24);
              std::memcpy(q, &oh, 4); std::memcpy(q + 4, &fv, 4); q += 8;
            }
            if (optDrop) {                     // epb_dropcount
              uint32_t oh = 4 | (8u << 16); uint64_t dv = drops;
              std::memcpy(q, &oh, 4); std::memcpy(q + 4, &dv, 8); q += 12;
            }
            if (optFlags || optDrop) { uint32_t z = 0; std::memcpy(q, &z, 4); q += 4; }
            std::memcpy(q, &total, 4);
            c->len += total;
          } else {
            uint32_t ph[4] = {uint32_t(ns / 1000000000), uint32_t(ns % 1000000000), clen, wlen};
            std::memcpy(d, ph, 16);
            copyOut(d + 16, tail + 16, clen);
            c->len += 16 + clen;
          }
        }
        if (o.check && clen >= 24) {
          uint64_t seq;
          copyOut(reinterpret_cast<uint8_t*>(&seq), tail + 16 + 16, 8);
          if (haveSeq[port] && seq != nextSeq[port] + drops) {
            // the record's drop field saturates at 65535: a longer gap is consistent with it
            if (drops == 0xFFFF && seq - nextSeq[port] >= 0xFFFF) st.seqSaturated++;
            else st.seqErrors++;
          }
          nextSeq[port] = seq + 1;
          haveSeq[port] = true;
        }
        PortStats& ps = st.p[port];
        st.records.fetch_add(1, std::memory_order_relaxed);
        ps.records.fetch_add(1, std::memory_order_relaxed);
        ps.bytes.fetch_add(clen, std::memory_order_relaxed);
        ps.wireBytes.fetch_add(wlen, std::memory_order_relaxed);
        if (drops) ps.drops.fetch_add(drops, std::memory_order_relaxed);
        if (drops == 0xFFFF) ps.dropsCapped.fetch_add(1, std::memory_order_relaxed);
        if (flags & F_BAD) ps.bad.fetch_add(1, std::memory_order_relaxed);
        if (flags & F_TRUNC) ps.trunc.fetch_add(1, std::memory_order_relaxed);
        tail += rlen;
        progressed = true;
        if (tail - lastTailWr >= ringSize / 8) {   // return space early on long bursts
          bar.wr(C_TAIL, uint32_t(tail));
          lastTailWr = tail;
          st.tail.store(tail, std::memory_order_relaxed);   // keeps the ring fill display <= 100%
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
  uint32_t fm = bar.rd(C_FIFO_MAX);
  for (int p = 0; p < 2; ++p)
    std::fprintf(f, "fpga %s: rx_frames %llu rx_bytes %llu captured %llu dropped %llu bad %llu fifo_max %u/32768 words\n",
                 kPortName[p], (unsigned long long)bar.rd64(kRxFrames[p]), (unsigned long long)bar.rd64(kRxBytes[p]),
                 (unsigned long long)bar.rd64(kCapFrames[p]), (unsigned long long)bar.rd64(kDropFrames[p]),
                 (unsigned long long)bar.rd64(kBadFrames[p]), p ? fm >> 16 : fm & 0xFFFF);
  std::fprintf(f, "fpga: records %llu tlps %llu ring_full_stalls %llu\n",
               (unsigned long long)bar.rd64(C_RECORDS), (unsigned long long)bar.rd64(C_TLPS),
               (unsigned long long)bar.rd64(C_STALLS));
}

}  // namespace

int main(int argc, char** argv) {
  try {
    Opts o = parse(argc, argv);
    std::string bdf = o.bdf.empty() ? findDevice() : o.bdf;
    Bar bar(bdf);
    if (bar.rd(R_ID) != 0x4B375043 || (bar.rd(R_VER) >> 16) != 0x0007) {
      errno = 0;
      die("unexpected ID/VERSION " + std::to_string(bar.rd(R_VER) >> 16) +
          " (not the k7_cap_ab bitstream; k7_cap has its own k7cap)");
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
    bar.wr(C_PORTS, o.ports);
    bar.wr(C_CTRL, flags);            // out of reset, not yet enabled
    usleep(1000);
    uint32_t status = bar.rd(C_STATUS);
    if (!(status & 1)) { errno = 0; die("bus mastering is off"); }
    uint32_t eth = bar.rd(R_ETH);
    std::fprintf(info, "k7cap: device %s, MPS %u, ports %s%s (SFP A %s, SFP B %s), ring %zu MB (%zu hugepages), snaplen %u%s%s%s%s\n",
                 bdf.c_str(), 128u << ((status >> 2) & 7), o.ports & 1 ? "A" : "", o.ports & 2 ? "B" : "",
                 (eth >> 16) & 1 ? "block lock" : "NO LOCK", (eth >> 24) & 1 ? "block lock" : "NO LOCK",
                 o.ringMb, nblk, o.snap, o.keepBad ? ", keep bad" : "", o.keepFcs ? ", keep FCS" : "",
                 o.tg ? ", TEST GENERATORS" : "", o.out.empty() ? "" : o.pcapng ? ", pcapng" : ", pcap");

    // timestamp anchor: FPGA ticks vs CLOCK_REALTIME (midpoint of the MMIO read)
    int64_t a = nowNs();
    uint64_t ts0 = bar.rd64(C_TS);
    int64_t b = nowNs();
    int64_t t0ns = a + (b - a) / 2;

    Writer w(o.out, 64, 4u << 20);
    size_t hdrBytes = 0;
    if (w.enabled()) {
      if (o.pcapng) {
        std::vector<uint8_t> h = pcapngHeader(o.snap, o.keepFcs);
        w.writeRaw(h.data(), h.size());
        hdrBytes = h.size();
      } else {
        uint32_t gh[6] = {0xa1b23c4d, 0x00040002, 0, 0, o.snap, 1};   // pcap, ns, Ethernet
        w.writeRaw(gh, sizeof gh);
        hdrBytes = sizeof gh;
      }
    }
    RxStats st;
    Rx rx{o, bar, mem, w, st, ringSize, ts0, t0ns};
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    std::thread rxThread([&] { rx.run(); });

    bar.wr(C_CTRL, flags | CTRL_EN);
    auto start = std::chrono::steady_clock::now();
    auto last = start;
    uint64_t lastRec[2] = {0, 0}, lastBytes[2] = {0, 0};
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
        // tail first: the consumer never passes the FPGA head, so head - tail cannot wrap
        uint64_t tail = st.tail.load();
        uint64_t head = bar.rd64(C_HEAD);
        std::string line;
        char buf[200];
        for (int p = 0; p < 2; ++p) {
          if (!(o.ports & (1u << p))) continue;
          uint64_t r = st.p[p].records, by = st.p[p].bytes;
          std::snprintf(buf, sizeof buf, "  %s %9.0f pkt/s %6.3f Gbit/s drops %llu (fpga %llu)", kPortName[p],
                        (r - lastRec[p]) / dt, (by - lastBytes[p]) * 8e-9 / dt,
                        (unsigned long long)st.p[p].drops.load(), (unsigned long long)bar.rd64(kDropFrames[p]));
          line += buf;
          lastRec[p] = r; lastBytes[p] = by;
        }
        if (!o.quiet)
          std::fprintf(info, "%6.0fs%s  recs %llu  ring %4.1f%%  backlog %zu\n", el, line.c_str(),
                       (unsigned long long)st.records.load(),
                       100.0 * double(head > tail ? head - tail : 0) / double(ringSize), w.backlog());
        last = now;
      }
    }

    // ---- stop: no new frames, drain what the FPGA has buffered ----
    bar.wr(C_CTRL, flags);
    uint64_t prev = ~0ull;
    for (int i = 0; i < 200; ++i) {                 // up to 2 s
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      uint64_t h = bar.rd64(C_HEAD);
      if (h == prev && st.tail.load() == h &&
          bar.rd64(C_RECORDS) == bar.rd64(kCapFrames[0]) + bar.rd64(kCapFrames[1])) break;
      prev = h;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));   // counter snapshots (105 us)
    rx.done = true;
    rxThread.join();
    w.drain();

    bool ok = st.badPort.load() == 0;
    for (int p = 0; p < 2; ++p) {
      const PortStats& ps = st.p[p];
      std::fprintf(info, "host %s: records %llu bytes %llu (wire %llu) drops-in-records %llu bad %llu truncated %llu\n",
                   kPortName[p], (unsigned long long)ps.records.load(), (unsigned long long)ps.bytes.load(),
                   (unsigned long long)ps.wireBytes.load(), (unsigned long long)ps.drops.load(),
                   (unsigned long long)ps.bad.load(), (unsigned long long)ps.trunc.load());
    }
    std::fprintf(info, "host: records %llu writer-waits %llu %s-bytes %llu%s\n",
                 (unsigned long long)st.records.load(), (unsigned long long)st.chunkWaits.load(),
                 o.pcapng ? "pcapng" : "pcap", (unsigned long long)(w.written() + hdrBytes),
                 st.badPort.load() ? "  RECORDS WITH A BAD PORT NUMBER" : "");
    printFpga(bar, info);
    if (o.tg) std::fprintf(info, "testgen: generated A %llu B %llu, sequence errors %llu, gaps over 65535 drops %llu\n",
                           (unsigned long long)bar.rd64(kTgSeq[0]), (unsigned long long)bar.rd64(kTgSeq[1]),
                           (unsigned long long)st.seqErrors.load(), (unsigned long long)st.seqSaturated.load());
    for (int p = 0; p < 2; ++p) {
      if (!(o.ports & (1u << p))) continue;
      uint64_t fCap = bar.rd64(kCapFrames[p]), fDrop = bar.rd64(kDropFrames[p]);
      bool pok = st.p[p].records.load() == fCap;
      ok = ok && pok;
      std::fprintf(info, "%s %s: host records %s FPGA captured (%llu); FPGA dropped %llu (%llu reported inside records, the rest %s)\n",
                   pok ? "OK" : "MISMATCH", kPortName[p], pok ? "==" : "!=", (unsigned long long)fCap,
                   (unsigned long long)fDrop, (unsigned long long)st.p[p].drops.load(),
                   cappedNote(st.p[p].dropsCapped.load()).c_str());
    }
    bar.wr(C_CTRL, CTRL_RESET);
    return ok && st.seqErrors.load() == 0 ? 0 : 1;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "k7cap: %s\n", e.what());
    return 1;
  }
}
