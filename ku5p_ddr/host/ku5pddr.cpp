// ku5pddr: exercise the 2 GB DDR4 on the KU5P board (ku5p_ddr design, 10ee:9021,
// ID "KUPC", FEAT[2]) from Linux user space: no kernel driver, BAR0 via sysfs,
// DMA buffers in 2 MB hugepages with physical addresses from /proc/self/pagemap
// (needs root and no IOMMU, like k7cap).
//
//   ku5pddr [-d BDF] status
//   ku5pddr ... memtest [-m MODE|all] [-s SEED] [-w|-r] [BASE LEN]  in-FPGA test, default all 2 GB
//   ku5pddr ... dmatest [-n MB] [-s SEED]     host writes random data over DMA, reads it back,
//                                             verifies; reports bandwidth (default all 2 GB)
//   ku5pddr ... write FILE [DDR_ADDR]         file -> DDR (DMA)
//   ku5pddr ... read  FILE DDR_ADDR LEN       DDR -> file (DMA)
//   ku5pddr ... peek ADDR                     one 32-byte word (register access, no DMA)
//   ku5pddr ... poke ADDR W0 [W1 .. W7]       write one 32-byte word (missing words = 0)
//   ku5pddr ... recal                         reset the memory controller and recalibrate
//
// Numbers accept 0x, and K/M/G suffixes. MODE: 0 addr^seed, 1 ~(addr^seed),
// 2 xorshift(addr^seed), 3 seed/~seed alternating, all = 0..3.
//
// Build: g++ -O2 -std=c++17 -o ku5pddr ku5pddr.cpp
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t R_ID = 0x000, R_VER = 0x004, R_LINK = 0x018, R_FEAT = 0x020;
constexpr uint32_t D_STATUS = 0xC00, D_INFO = 0xC04, D_CTRL = 0xC08;
constexpr uint32_t MT_CTRL = 0xC10, MT_BASE = 0xC14, MT_LEN = 0xC18, MT_SEED = 0xC1C, MT_ERRS = 0xC20,
                   MT_WCYC = 0xC24, MT_RCYC = 0xC28, MT_EADDR = 0xC2C, MT_EEXP = 0xC30, MT_EGOT = 0xC34;
constexpr uint32_t DMA_HLO = 0xC40, DMA_HHI = 0xC44, DMA_DDR = 0xC48, DMA_LEN = 0xC4C, DMA_CTRL = 0xC50,
                   DMA_ST = 0xC54, DMA_CYC = 0xC58, DMA_DBG = 0xC5C;
constexpr uint32_t SA_ADDR = 0xC80, SA_CTRL = 0xC84, SA_DATA = 0xCA0;
constexpr uint64_t kDdrSize = 2ull << 30;
constexpr size_t kHuge = 2u << 20;
constexpr double kUserMHz = 250.0;

[[noreturn]] void die(const std::string& m) {
  if (errno) throw std::runtime_error(m + ": " + std::strerror(errno));
  throw std::runtime_error(m);
}

std::string readLine(const std::string& p) {
  std::ifstream f(p);
  std::string s;
  std::getline(f, s);
  return s;
}

uint64_t num(const std::string& s) {
  char* e = nullptr;
  uint64_t v = std::strtoull(s.c_str(), &e, 0);
  if (e == s.c_str()) { errno = 0; die("bad number " + s); }
  switch (*e) {
    case 'k': case 'K': v <<= 10; break;
    case 'm': case 'M': v <<= 20; break;
    case 'g': case 'G': v <<= 30; break;
    case 0: break;
    default: errno = 0; die("bad number " + s);
  }
  return v;
}

std::string findDevice(std::string want) {
  if (!want.empty() && want.find(':') == want.rfind(':')) want = "0000:" + want;
  if (!want.empty()) return want;
  DIR* d = opendir("/sys/bus/pci/devices");
  if (!d) die("open /sys/bus/pci/devices");
  std::vector<std::string> hit;
  while (dirent* e = readdir(d)) {
    if (e->d_name[0] == '.') continue;
    std::string b = std::string("/sys/bus/pci/devices/") + e->d_name;
    if (readLine(b + "/vendor") == "0x10ee" && readLine(b + "/device") == "0x9021") hit.push_back(e->d_name);
  }
  closedir(d);
  errno = 0;
  if (hit.empty()) die("no 10ee:9021 device found");
  if (hit.size() > 1) die("several 10ee:9021 devices, pick one with -d");
  return hit[0];
}

class Bar {
 public:
  explicit Bar(const std::string& bdf) {
    std::string base = "/sys/bus/pci/devices/" + bdf;
    // memory decoding + bus mastering (no driver is bound)
    int cfg = open((base + "/config").c_str(), O_RDWR);
    if (cfg < 0) die("open " + base + "/config (root?)");
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

 private:
  int fd_ = -1;
  volatile uint32_t* m_ = nullptr;
};

uint64_t physOf(const void* v) {
  static int fd = open("/proc/self/pagemap", O_RDONLY);
  if (fd < 0) die("open /proc/self/pagemap");
  uint64_t va = reinterpret_cast<uint64_t>(v), ent = 0;
  if (pread(fd, &ent, 8, (va / 4096) * 8) != 8) die("read pagemap");
  if (!(ent >> 63) || (ent & ((1ull << 55) - 1)) == 0) { errno = 0; die("pagemap gives no physical address (root?)"); }
  return (ent & ((1ull << 55) - 1)) * 4096 + (va & 4095);
}

// n 2 MB hugepages, each physically contiguous (one DMA transfer each)
struct DmaMem {
  uint8_t* base = nullptr;
  size_t pages = 0;
  std::vector<uint64_t> phys;
  explicit DmaMem(size_t n) : pages(n) {
    long have = std::strtol(readLine("/proc/sys/vm/nr_hugepages").c_str(), nullptr, 10);
    long freeP = std::strtol(readLine("/sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages").c_str(), nullptr, 10);
    if (freeP < long(n))
      if (FILE* f = std::fopen("/proc/sys/vm/nr_hugepages", "w")) {
        std::fprintf(f, "%ld\n", have + long(n) - freeP);
        std::fclose(f);
      }
    void* p = mmap(nullptr, n * kHuge, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE | MAP_LOCKED, -1, 0);
    if (p == MAP_FAILED) die("mmap " + std::to_string(n) + " x 2 MB hugepages (see /proc/meminfo)");
    base = static_cast<uint8_t*>(p);
    std::memset(base, 0, n * kHuge);
    for (size_t i = 0; i < n; ++i) {
      phys.push_back(physOf(base + i * kHuge));
      if (physOf(base + i * kHuge + kHuge - 4096) != phys.back() + kHuge - 4096) { errno = 0; die("hugepage not contiguous"); }
    }
  }
  ~DmaMem() { if (base) munmap(base, pages * kHuge); }
  uint8_t* page(size_t i) const { return base + i * kHuge; }
};

class Ddr {
 public:
  explicit Ddr(const Bar& b) : b_(b) {
    errno = 0;
    if (b_.rd(R_ID) != 0x4B555043) die("ID register is not KUPC (wrong design or BAR not working)");
    if (!(b_.rd(R_FEAT) & 4)) die("design has no DDR block (FEAT[2]); load the ku5p_ddr bitstream");
    uint32_t info = b_.rd(D_INFO);
    uiMHz_ = (info >> 24) ? double(info >> 24) : 300.0;
  }
  double uiMHz() const { return uiMHz_; }
  uint32_t st() const { return b_.rd(D_STATUS); }
  void needCalib() const {
    errno = 0;
    uint32_t s = st();
    if (!(s & 1)) die("DDR not calibrated (status " + hex(s) + ")");
  }
  static std::string hex(uint32_t v) {
    char t[16];
    std::snprintf(t, sizeof t, "0x%08x", v);
    return t;
  }

  // one DMA transfer; returns user_clk cycles
  uint32_t dma(uint64_t host, uint32_t ddr, uint32_t len, bool c2h) const {
    b_.wr(DMA_HLO, uint32_t(host));
    b_.wr(DMA_HHI, uint32_t(host >> 32));
    b_.wr(DMA_DDR, ddr);
    b_.wr(DMA_LEN, len);
    b_.wr(DMA_CTRL, 1u | (c2h ? 2u : 0u));
    uint32_t s;
    auto t0 = std::chrono::steady_clock::now();
    while (((s = b_.rd(DMA_ST)) & 3) != 2) {
      if (std::chrono::steady_clock::now() - t0 > std::chrono::seconds(5)) {
        errno = 0;
        die("DMA did not finish, status " + hex(s) + " dbg " + hex(b_.rd(DMA_DBG)));
      }
    }
    if (s & 4) {
      static const char* why[] = {"?", "bus mastering off", "completion error status", "timeout", "bad arguments"};
      unsigned code = (s >> 4) & 7;
      errno = 0;
      die(std::string("DMA error: ") + why[code < 5 ? code : 0] + " (" + hex(s) + ")");
    }
    return b_.rd(DMA_CYC);
  }

  // in-FPGA memory test; returns errors
  uint32_t memtest(uint32_t base, uint64_t len, int mode, uint32_t seed, bool wr, bool rdv) const {
    b_.wr(MT_BASE, base);
    b_.wr(MT_LEN, uint32_t(len));   // 2 GB wraps to 0x80000000, which the design takes as 2^26 words
    b_.wr(MT_SEED, seed);
    b_.wr(MT_CTRL, 1u | (wr ? 2u : 0u) | (rdv ? 4u : 0u) | (uint32_t(mode) << 4));
    auto t0 = std::chrono::steady_clock::now();
    while (!(st() & 8)) {
      if (std::chrono::steady_clock::now() - t0 > std::chrono::seconds(10)) { errno = 0; die("memtest did not finish"); }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    uint32_t errs = b_.rd(MT_ERRS);
    double wcyc = b_.rd(MT_WCYC), rcyc = b_.rd(MT_RCYC);
    std::printf("  mode %d seed 0x%08x: ", mode, seed);
    if (wr) std::printf("write %.2f GB/s  ", len / (wcyc / uiMHz_ * 1e-6) / 1e9);
    if (rdv) std::printf("read+verify %.2f GB/s  ", len / (rcyc / uiMHz_ * 1e-6) / 1e9);
    std::printf("errors %u\n", errs);
    if (errs)
      std::printf("    first at 0x%08x: expected 0x%08x got 0x%08x\n", b_.rd(MT_EADDR), b_.rd(MT_EEXP), b_.rd(MT_EGOT));
    return errs;
  }

  void peek(uint32_t a, uint32_t w[8]) const {
    b_.wr(SA_ADDR, a);
    b_.wr(SA_CTRL, 1);
    while (b_.rd(SA_CTRL) & 1) {}
    for (int i = 0; i < 8; ++i) w[i] = b_.rd(SA_DATA + 4 * i);
  }
  void poke(uint32_t a, const uint32_t w[8]) const {
    for (int i = 0; i < 8; ++i) b_.wr(SA_DATA + 4 * i, w[i]);
    b_.wr(SA_ADDR, a);
    b_.wr(SA_CTRL, 2);
    while (b_.rd(SA_CTRL) & 1) {}
  }

 private:
  const Bar& b_;
  double uiMHz_ = 300.0;
};

// deterministic random fill: xorshift64 seeded per 2 MB chunk
void fill(uint64_t* p, size_t n, uint64_t seed) {
  uint64_t x = seed * 0x9E3779B97F4A7C15ull + 0x1234567;
  for (size_t i = 0; i < n; ++i) {
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    p[i] = x;
  }
}

void status(const Bar& b) {
  uint32_t link = b.rd(R_LINK);
  static const char* gts[] = {"2.5", "5", "8", "?"};
  std::printf("ID 0x%08x  version 0x%08x  feat 0x%08x\n", b.rd(R_ID), b.rd(R_VER), b.rd(R_FEAT));
  std::printf("link %s, %s GT/s x%d\n", (link >> 15) & 1 ? "up" : "down", gts[(link >> 8) & 3], 1 << ((link >> 12) & 7));
  if (!(b.rd(R_FEAT) & 4)) { std::printf("no DDR block in this design\n"); return; }
  uint32_t s = b.rd(D_STATUS), info = b.rd(D_INFO);
  std::printf("DDR %u MB, %u-bit, ui_clk %u MHz\n", info & 0xFFFF, (info >> 16) & 0xFF, info >> 24);
  std::printf("status 0x%08x: calib %s%s, memtest %s%s, DMA %s%s%s\n", s, s & 1 ? "done" : "NOT done",
              s & 2 ? " (controller in reset)" : "", s & 4 ? "busy" : "idle", s & 8 ? " (done)" : "",
              s & 16 ? "busy" : "idle", s & 64 ? " (last one failed)" : "", s & 128 ? "" : ", bus mastering off");
  static const int mps[] = {128, 256, 512, 1024};
  std::printf("max payload %d B, max read request %d B\n", mps[(s >> 8) & 3], 128 << ((s >> 12) & 7));
}

int usage() {
  std::fprintf(stderr,
      "usage: ku5pddr [-d BDF] status | memtest [-m MODE|all] [-s SEED] [-w|-r] [BASE LEN] |\n"
      "       dmatest [-n MB] [-s SEED] | write FILE [DDR_ADDR] | read FILE DDR_ADDR LEN |\n"
      "       peek ADDR | poke ADDR W0..W7 | recal\n");
  return 2;
}

int run(int argc, char** argv) {
  std::string bdf;
  int i = 1;
  if (i + 1 < argc && std::string(argv[i]) == "-d") { bdf = argv[i + 1]; i += 2; }
  if (i >= argc) return usage();
  std::string cmd = argv[i++];
  std::vector<std::string> a(argv + i, argv + argc);
  Bar bar(findDevice(bdf));
  if (cmd == "status") { status(bar); return 0; }
  Ddr ddr(bar);

  if (cmd == "recal") {
    bar.wr(D_CTRL, 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    bar.wr(D_CTRL, 0);
    auto t0 = std::chrono::steady_clock::now();
    while (!(ddr.st() & 1)) {
      if (std::chrono::steady_clock::now() - t0 > std::chrono::seconds(3)) { errno = 0; die("calibration did not complete"); }
    }
    std::printf("calibrated in %.0f ms\n",
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
    return 0;
  }
  ddr.needCalib();

  if (cmd == "memtest") {
    int m0 = 0, m1 = 3;
    uint32_t seed = 0x5EED0000;
    bool wr = true, rdv = true;
    std::vector<std::string> pos;
    for (size_t k = 0; k < a.size(); ++k) {
      if (a[k] == "-m" && k + 1 < a.size()) {
        if (a[++k] != "all") m0 = m1 = int(num(a[k]) & 3);
      } else if (a[k] == "-s" && k + 1 < a.size()) seed = uint32_t(num(a[++k]));
      else if (a[k] == "-w") rdv = false;
      else if (a[k] == "-r") wr = false;
      else pos.push_back(a[k]);
    }
    uint64_t base = pos.size() > 0 ? num(pos[0]) : 0, len = pos.size() > 1 ? num(pos[1]) : kDdrSize - base;
    errno = 0;
    if (base % 32 || len % 32 || len == 0 || base + len > kDdrSize) die("BASE/LEN must be 32-byte multiples inside 2 GB");
    std::printf("memtest 0x%08llx + %llu MB\n", (unsigned long long)base, (unsigned long long)(len >> 20));
    uint64_t errs = 0;
    for (int m = m0; m <= m1; ++m) errs += ddr.memtest(uint32_t(base), len, m, seed + m, wr, rdv);
    std::printf("%s\n", errs ? "FAILED" : "PASSED");
    return errs ? 1 : 0;
  }

  if (cmd == "dmatest") {
    uint64_t mb = 2048;
    uint64_t seed = 1;
    for (size_t k = 0; k + 1 < a.size(); ++k) {
      if (a[k] == "-n") mb = num(a[++k]);
      else if (a[k] == "-s") seed = num(a[++k]);
    }
    errno = 0;
    if (mb == 0 || mb % 2 || mb > 2048) die("-n must be an even number of MB, at most 2048");
    size_t chunks = mb / 2;
    DmaMem mem(2);   // page 0: data to the card, page 1: data back
    uint64_t* tx = reinterpret_cast<uint64_t*>(mem.page(0));
    uint64_t* rx = reinterpret_cast<uint64_t*>(mem.page(1));
    double cyc_w = 0, cyc_r = 0;
    auto t0 = std::chrono::steady_clock::now();
    for (size_t c = 0; c < chunks; ++c) {
      fill(tx, kHuge / 8, seed + c);
      cyc_w += ddr.dma(mem.phys[0], uint32_t(c * kHuge), kHuge, false);
    }
    auto t1 = std::chrono::steady_clock::now();
    uint64_t bad = 0;
    for (size_t c = 0; c < chunks; ++c) {
      std::memset(rx, 0, kHuge);
      cyc_r += ddr.dma(mem.phys[1], uint32_t(c * kHuge), kHuge, true);
      fill(tx, kHuge / 8, seed + c);
      if (std::memcmp(tx, rx, kHuge)) {
        for (size_t k = 0; k < kHuge / 8; ++k)
          if (tx[k] != rx[k]) {
            if (bad < 5)
              std::printf("  mismatch at DDR 0x%08llx: wrote %016llx read %016llx\n",
                          (unsigned long long)(c * kHuge + 8 * k), (unsigned long long)tx[k], (unsigned long long)rx[k]);
            ++bad;
          }
      }
    }
    auto t2 = std::chrono::steady_clock::now();
    double bytes = double(chunks) * kHuge;
    std::printf("dmatest %llu MB: host->DDR %.2f GB/s (engine) , DDR->host %.2f GB/s (engine)\n",
                (unsigned long long)mb, bytes / (cyc_w / kUserMHz * 1e-6) / 1e9,
                bytes / (cyc_r / kUserMHz * 1e-6) / 1e9);
    std::printf("  wall time: write %.2f s, read+verify %.2f s\n",
                std::chrono::duration<double>(t1 - t0).count(), std::chrono::duration<double>(t2 - t1).count());
    std::printf("%s (%llu mismatched 64-bit words)\n", bad ? "FAILED" : "PASSED", (unsigned long long)bad);
    return bad ? 1 : 0;
  }

  if (cmd == "write" || cmd == "read") {
    errno = 0;
    if (a.empty() || (cmd == "read" && a.size() < 3)) return usage();
    uint64_t daddr = a.size() > 1 ? num(a[1]) : 0;
    if (daddr % 32) die("DDR_ADDR must be 32-byte aligned");
    DmaMem mem(1);
    if (cmd == "write") {
      FILE* f = std::fopen(a[0].c_str(), "rb");
      if (!f) die("open " + a[0]);
      uint64_t total = 0;
      for (;;) {
        size_t n = std::fread(mem.page(0), 1, kHuge, f);
        if (n == 0) break;
        size_t padded = (n + 511) & ~size_t(511);
        std::memset(mem.page(0) + n, 0, padded - n);
        if (daddr + total + padded > kDdrSize) { errno = 0; die("file does not fit in DDR"); }
        ddr.dma(mem.phys[0], uint32_t(daddr + total), uint32_t(padded), false);
        total += n;
      }
      std::fclose(f);
      std::printf("wrote %llu bytes to DDR 0x%08llx\n", (unsigned long long)total, (unsigned long long)daddr);
    } else {
      uint64_t len = num(a[2]);
      if (daddr + len > kDdrSize) { errno = 0; die("range outside 2 GB"); }
      FILE* f = std::fopen(a[0].c_str(), "wb");
      if (!f) die("create " + a[0]);
      for (uint64_t done = 0; done < len;) {
        uint64_t n = std::min<uint64_t>(len - done, kHuge);
        uint64_t padded = (n + 511) & ~uint64_t(511);
        if (daddr + done + padded > kDdrSize) padded = n;   // still a 512 multiple at the top end if len is
        ddr.dma(mem.phys[0], uint32_t(daddr + done), uint32_t(padded), true);
        std::fwrite(mem.page(0), 1, n, f);
        done += n;
      }
      std::fclose(f);
      std::printf("read %llu bytes from DDR 0x%08llx\n", (unsigned long long)len, (unsigned long long)daddr);
    }
    return 0;
  }

  if (cmd == "peek" && a.size() == 1) {
    uint32_t w[8];
    uint32_t ad = uint32_t(num(a[0])) & ~31u;
    ddr.peek(ad, w);
    std::printf("0x%08x:", ad);
    for (int k = 0; k < 8; ++k) std::printf(" %08x", w[k]);
    std::printf("\n");
    return 0;
  }
  if (cmd == "poke" && a.size() >= 2) {
    uint32_t w[8] = {};
    for (size_t k = 1; k < a.size() && k <= 8; ++k) w[k - 1] = uint32_t(num(a[k]));
    ddr.poke(uint32_t(num(a[0])) & ~31u, w);
    return 0;
  }
  return usage();
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return run(argc, argv);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "ku5pddr: %s\n", e.what());
    return 1;
  }
}
