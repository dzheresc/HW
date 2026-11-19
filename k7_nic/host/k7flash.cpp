// k7flash: program the K7 board's SPI configuration flash over PCIe.
// The FPGA design (k7_pcie) exposes a buffered SPI master in BAR0; this tool
// maps BAR0 through sysfs (needs root) and talks to the flash with it.
//
//   k7flash [-d BDF] info
//   k7flash [-d BDF] read   FILE [OFFSET [LEN]]       (default: whole flash)
//   k7flash [-d BDF] verify FILE [OFFSET]
//   k7flash [-d BDF] erase  OFFSET LEN               (rounded out to sectors)
//   k7flash [-d BDF] write  FILE [OFFSET]            (erase + program + verify)
//   k7flash [-d BDF] status                          (registers / link)
//
// Build: g++ -O2 -std=c++17 -o k7flash k7flash.cpp
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
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t kVendor = 0x10EE, kDevice = 0x7021, kMagic = 0x4B375043;
constexpr uint32_t R_ID = 0x000, R_VER = 0x004, R_STATUS = 0x008, R_CTRL = 0x00C,
                   R_XFER = 0x010, R_SCRATCH = 0x014, R_LINK = 0x018, R_CSREL = 0x01C,
                   R_ETH = 0x020,  // k7_nic (VERSION >= 2): status, then 8 rate words
                   R_TX = 0x400, R_RX = 0x800;
constexpr size_t kBuf = 1024;

[[noreturn]] void die(const std::string& m) { throw std::runtime_error(m); }

std::string readFile1(const std::string& p) {
  std::ifstream f(p);
  std::string s;
  std::getline(f, s);
  return s;
}

std::string findDevice() {
  DIR* d = opendir("/sys/bus/pci/devices");
  if (!d) die("cannot open /sys/bus/pci/devices");
  std::string found;
  while (dirent* e = readdir(d)) {
    if (e->d_name[0] == '.') continue;
    std::string base = std::string("/sys/bus/pci/devices/") + e->d_name;
    if (std::strtoul(readFile1(base + "/vendor").c_str(), nullptr, 16) == kVendor &&
        std::strtoul(readFile1(base + "/device").c_str(), nullptr, 16) == kDevice) {
      found = e->d_name;
      break;
    }
  }
  closedir(d);
  if (found.empty()) die("no 10ee:7021 device found (load the bitstream, then rescan the bus)");
  return found;
}

class Bar {
 public:
  explicit Bar(const std::string& bdf) {
    std::string base = "/sys/bus/pci/devices/" + bdf;
    // make sure memory decoding is on (no driver is bound to the device)
    if (FILE* en = std::fopen((base + "/enable").c_str(), "w")) {
      std::fputs("1", en);
      std::fclose(en);
    }
    fd_ = open((base + "/resource0").c_str(), O_RDWR | O_SYNC);
    if (fd_ < 0) die("open resource0 failed (run as root?)");
    p_ = static_cast<volatile uint32_t*>(mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0));
    if (p_ == MAP_FAILED) die("mmap BAR0 failed");
  }
  ~Bar() {
    munmap(const_cast<uint32_t*>(p_), 4096);
    close(fd_);
  }
  uint32_t rd(uint32_t off) const { return p_[off / 4]; }
  void wr(uint32_t off, uint32_t v) const { p_[off / 4] = v; }

 private:
  int fd_ = -1;
  volatile uint32_t* p_ = nullptr;
};

class Spi {
 public:
  explicit Spi(const Bar& b) : b_(b) {}

  // Shift out tx, then n - tx.size() more bytes (MOSI content is whatever is left in TXBUF; the flash ignores it); returns the n received bytes.
  std::vector<uint8_t> xfer(const std::vector<uint8_t>& tx, size_t n, bool keepCs = false) {
    if (n == 0 || n > kBuf || tx.size() > n) die("bad transfer size");
    for (size_t i = 0; i < tx.size(); i += 4) {
      uint32_t w = 0;
      for (size_t j = 0; j < 4; ++j) w |= uint32_t(i + j < tx.size() ? tx[i + j] : 0xFF) << (8 * j);
      b_.wr(R_TX + i, w);
    }
    waitIdle();
    b_.wr(R_XFER, uint32_t(n) | (keepCs ? 0x80000000u : 0));
    waitIdle();
    std::vector<uint8_t> rx(n);
    for (size_t i = 0; i < n; i += 4) {
      uint32_t w = b_.rd(R_RX + i);
      if (w == 0xFFFFFFFF && b_.rd(R_ID) != kMagic) die("device stopped responding");
      for (size_t j = 0; j < 4 && i + j < n; ++j) rx[i + j] = uint8_t(w >> (8 * j));
    }
    return rx;
  }
  void waitIdle() {
    for (int i = 0; i < 1000000; ++i) {
      uint32_t s = b_.rd(R_STATUS);
      if (s == 0xFFFFFFFF) die("device returned all-ones (link down?)");
      if (!(s & 1)) return;
    }
    die("SPI engine stuck busy");
  }

 private:
  const Bar& b_;
};

struct EraseType {
  uint32_t size = 0;
  uint8_t op = 0;
};

class Flash {
 public:
  explicit Flash(Spi& s) : s_(s) { probe(); }

  uint32_t size() const { return size_; }
  const EraseType& erase() const { return erase_; }
  const uint8_t* jedec() const { return id_; }
  bool addr4() const { return addr4_; }

  uint8_t rdsr() { return s_.xfer({0x05}, 2)[1]; }
  void wren() {
    s_.xfer({0x06}, 1);
    if (!(rdsr() & 0x02)) die("write enable did not latch (WP?)");
  }
  void waitWip(double timeoutSec) {
    auto t0 = std::chrono::steady_clock::now();
    while (rdsr() & 0x01) {
      if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > timeoutSec)
        die("flash busy timeout");
    }
  }

  void read(uint32_t addr, uint8_t* out, size_t len) {
    const size_t hdr = addr4_ ? 5 : 4;
    while (len) {
      size_t n = std::min(len, kBuf - hdr);
      auto rx = s_.xfer(cmd(addr4_ ? 0x13 : 0x03, addr), hdr + n);
      std::memcpy(out, rx.data() + hdr, n);
      out += n; addr += n; len -= n;
    }
  }
  void eraseSector(uint32_t addr) { eraseOp(erase_.op, addr, 10.0); }
  // 4 KB erase; on Spansion S25FL-S hybrid parts only valid in the parameter sectors
  void erase4k(uint32_t addr) { eraseOp(addr4_ ? 0x21 : 0x20, addr, 2.0); }
  void eraseOp(uint8_t op, uint32_t addr, double tmo) {
    wren();
    s_.xfer(cmd(op, addr), addr4_ ? 5 : 4);
    waitWip(tmo);
    checkErr("erase");
  }
  void checkErr(const char* what) {
    if (id_[0] == 0x01 && (rdsr() & 0x60)) {  // Spansion E_ERR / P_ERR
      s_.xfer({0x30}, 1);                      // clear status register
      die(std::string(what) + " error reported by flash (protected sector?)");
    }
  }
  void programPage(uint32_t addr, const uint8_t* data, size_t len) {  // within one page
    std::vector<uint8_t> tx = cmd(addr4_ ? 0x12 : 0x02, addr);
    tx.insert(tx.end(), data, data + len);
    wren();
    s_.xfer(tx, tx.size());
    waitWip(1.0);
    checkErr("program");
  }

 private:
  std::vector<uint8_t> cmd(uint8_t op, uint32_t a) const {
    if (addr4_) return {op, uint8_t(a >> 24), uint8_t(a >> 16), uint8_t(a >> 8), uint8_t(a)};
    return {op, uint8_t(a >> 16), uint8_t(a >> 8), uint8_t(a)};
  }

  void probe() {
    auto r = s_.xfer({0x9F}, 4);
    std::memcpy(id_, r.data() + 1, 3);
    if ((id_[0] == 0xFF && id_[1] == 0xFF) || (id_[0] == 0 && id_[1] == 0))
      die("no flash answered the JEDEC ID command");
    // SFDP: header, first parameter header -> basic flash parameter table
    auto h = s_.xfer({0x5A, 0, 0, 0, 0}, 5 + 16);
    const uint8_t* sf = h.data() + 5;
    if (sf[0] == 'S' && sf[1] == 'F' && sf[2] == 'D' && sf[3] == 'P') {
      uint32_t ptp = sf[12] | (sf[13] << 8) | (sf[14] << 16);
      uint8_t words = sf[11];
      auto t = s_.xfer({0x5A, uint8_t(ptp >> 16), uint8_t(ptp >> 8), uint8_t(ptp), 0}, 5 + 4 * words);
      auto dw = [&](int i) {
        const uint8_t* p = t.data() + 5 + 4 * (i - 1);
        return uint32_t(p[0]) | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24);
      };
      uint32_t dens = dw(2);
      size_ = (dens & 0x80000000u) ? (1u << ((dens & 0x7FFFFFFF) - 3)) : (dens + 1) / 8;
      for (int i = 0; i < 4 && words >= 9; ++i) {
        uint32_t w = i < 2 ? dw(8) : dw(9);
        uint8_t exp = (w >> (16 * (i & 1))) & 0xFF, op = (w >> (16 * (i & 1) + 8)) & 0xFF;
        // prefer 64 KB, else the largest offered
        if (exp && (exp == 16 || (erase_.size != 65536 && (1u << exp) > erase_.size))) {
          erase_.size = 1u << exp;
          erase_.op = op;
        }
      }
      sfdp_ = true;
    }
    if (!size_) size_ = 1u << id_[2];  // common JEDEC convention
    if (!erase_.size) erase_ = {65536, 0xD8};
    addr4_ = size_ > (16u << 20);
    if (addr4_) {  // 4-byte-address opcode variants
      if (erase_.op == 0xD8) erase_.op = 0xDC;
      else if (erase_.op == 0x20) erase_.op = 0x21;
      else if (erase_.op == 0x52) erase_.op = 0x5C;
    }
  }

  Spi& s_;
  uint8_t id_[3] = {};
  uint32_t size_ = 0;
  EraseType erase_;
  bool addr4_ = false;
  bool sfdp_ = false;
};

std::vector<uint8_t> loadFile(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  if (!f) die("cannot open " + p);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), {});
}

uint32_t num(const char* s) { return uint32_t(std::strtoul(s, nullptr, 0)); }

void progress(const char* what, size_t done, size_t total) {
  std::fprintf(stderr, "\r%s %zu / %zu KiB", what, done >> 10, total >> 10);
  if (done == total) std::fputc('\n', stderr);
}

double secs(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

bool verify(Flash& f, uint32_t off, const std::vector<uint8_t>& want) {
  std::vector<uint8_t> got(64 * 1024);
  for (size_t i = 0; i < want.size(); i += got.size()) {
    size_t n = std::min(got.size(), want.size() - i);
    f.read(off + i, got.data(), n);
    if (std::memcmp(got.data(), want.data() + i, n)) {
      for (size_t j = 0; j < n; ++j)
        if (got[j] != want[i + j]) {
          std::fprintf(stderr, "\nverify mismatch at 0x%08zx: flash %02x file %02x\n", off + i + j, got[j], want[i + j]);
          return false;
        }
    }
    progress("verify", i + n, want.size());
  }
  return true;
}

void eraseRange(Flash& f, uint32_t off, uint32_t len) {
  uint32_t es = f.erase().size;
  uint32_t a0 = off / es * es, a1 = (off + len + es - 1) / es * es;
  std::vector<uint8_t> chk(es);
  auto isBlank = [&](uint32_t a, uint32_t n) {
    f.read(a, chk.data(), n);
    for (uint32_t j = 0; j < n; ++j) if (chk[j] != 0xFF) return false;
    return true;
  };
  for (uint32_t a = a0; a < a1; a += es) {
    // skip sectors that are already blank
    if (!isBlank(a, es)) {
      f.eraseSector(a);
      // Hybrid-sector parts (e.g. S25FL256S with 4 KB parameter sectors) may
      // leave the parameter sectors untouched by a 64 KB erase: mop up in 4 KB.
      if (!isBlank(a, es)) {
        for (uint32_t b = a; b < a + es; b += 4096)
          if (!isBlank(b, 4096)) f.erase4k(b);
        if (!isBlank(a, es)) die("sector at " + std::to_string(a) + " is not blank after erase");
      }
    }
    progress("erase ", a + es - a0, a1 - a0);
  }
}

int run(int argc, char** argv) {
  std::string bdf;
  int i = 1;
  if (i + 1 < argc && std::string(argv[i]) == "-d") { bdf = argv[i + 1]; i += 2; }
  if (i >= argc) {
    std::fprintf(stderr, "usage: k7flash [-d BDF] info|status|read|verify|erase|write ...\n");
    return 2;
  }
  std::string op = argv[i++];
  if (bdf.empty()) bdf = findDevice();
  Bar bar(bdf);
  if (bar.rd(R_ID) != kMagic) die("unexpected ID register (wrong bitstream?)");

  if (op == "status") {
    uint32_t l = bar.rd(R_LINK);
    std::printf("device %s  ID %08x  VER %08x  STATUS %08x  CTRL %08x\n", bdf.c_str(), bar.rd(R_ID),
                bar.rd(R_VER), bar.rd(R_STATUS), bar.rd(R_CTRL));
    std::printf("link up %u  LTSSM 0x%02x  rate %s  width code %u\n", (l >> 15) & 1, l & 0x3F,
                (l >> 8) & 1 ? "5.0GT/s" : "2.5GT/s", (l >> 12) & 3);
    if (bar.rd(R_VER) >= 0x00020000) {  // k7_nic: 10GBASE-R status
      uint32_t e = bar.rd(R_ETH);
      auto b = [e](int n) { return (e >> n) & 1; };
      std::printf("10G: qpll %u txmmcm %u | txfsm A%u B%u rxfsm A%u B%u | rxmmcm A%u B%u | "
                  "TX PCS %u Hz, RX PCS A %u Hz\n", b(0), b(1), b(2), b(3), b(4), b(5), b(10), b(11),
                  bar.rd(R_ETH + 4), bar.rd(R_ETH + 8));
      for (int c = 0; c < 2; ++c) {
        uint32_t s = (e >> (16 + 8 * c)) & 0xFF, r = R_ETH + 12 + 12 * c;
        std::printf("SFP %c: block_lock %u high_ber %u rx_status %u errs %u | idle/s %u  "
                    "local-fault/s %u  remote-fault/s %u\n", 'A' + c, s & 1, (s >> 1) & 1,
                    (s >> 2) & 1, s >> 3, bar.rd(r), bar.rd(r + 4), bar.rd(r + 8));
      }
    }
    return 0;
  }

  Spi spi(bar);
  bar.wr(R_CSREL, 1);
  Flash f(spi);
  const uint8_t* id = f.jedec();

  if (op == "info") {
    std::printf("JEDEC ID   %02X %02X %02X\n", id[0], id[1], id[2]);
    std::printf("size       %u bytes (%u Mbit)\n", f.size(), f.size() >> 17);
    std::printf("erase      %u KiB, opcode 0x%02X\n", f.erase().size >> 10, f.erase().op);
    std::printf("addressing %s\n", f.addr4() ? "4-byte opcodes (0x13/0x12)" : "3-byte");
    std::printf("SR1        %02X\n", f.rdsr());
    if (id[0] == 0x01 && id[1] == 0x02 && id[2] == 0x19)
      std::printf("part       Spansion/Cypress S25FL256S (256 Mbit)\n");
    return 0;
  }
  if (op == "read") {
    if (i >= argc) die("read FILE [OFFSET [LEN]]");
    std::string path = argv[i++];
    uint32_t off = i < argc ? num(argv[i++]) : 0;
    uint32_t len = i < argc ? num(argv[i++]) : f.size() - off;
    std::vector<uint8_t> buf(len);
    auto t0 = std::chrono::steady_clock::now();
    for (size_t p = 0; p < len; p += 256 * 1024) {
      size_t n = std::min<size_t>(256 * 1024, len - p);
      f.read(off + p, buf.data() + p, n);
      progress("read  ", p + n, len);
    }
    std::ofstream o(path, std::ios::binary);
    o.write(reinterpret_cast<const char*>(buf.data()), buf.size());
    if (!o) die("write " + path + " failed");
    std::printf("read %u bytes from 0x%08x in %.1f s\n", len, off, secs(t0));
    return 0;
  }
  if (op == "verify") {
    if (i >= argc) die("verify FILE [OFFSET]");
    auto data = loadFile(argv[i++]);
    uint32_t off = i < argc ? num(argv[i++]) : 0;
    bool ok = verify(f, off, data);
    std::printf("verify %s\n", ok ? "OK" : "FAILED");
    return ok ? 0 : 1;
  }
  if (op == "erase") {
    if (i + 1 >= argc) die("erase OFFSET LEN");
    uint32_t off = num(argv[i]), len = num(argv[i + 1]);
    if (uint64_t(off) + len > f.size()) die("range past end of flash");
    auto t0 = std::chrono::steady_clock::now();
    eraseRange(f, off, len);
    std::printf("erased in %.1f s\n", secs(t0));
    return 0;
  }
  if (op == "write") {
    if (i >= argc) die("write FILE [OFFSET]");
    auto data = loadFile(argv[i++]);
    uint32_t off = i < argc ? num(argv[i++]) : 0;
    if (uint64_t(off) + data.size() > f.size()) die("file does not fit");
    auto t0 = std::chrono::steady_clock::now();
    eraseRange(f, off, uint32_t(data.size()));
    for (size_t p = 0; p < data.size();) {
      uint32_t a = off + p;
      size_t n = std::min<size_t>(256 - (a & 255), data.size() - p);
      bool blank = true;
      for (size_t j = 0; j < n; ++j) if (data[p + j] != 0xFF) { blank = false; break; }
      if (!blank) f.programPage(a, data.data() + p, n);
      p += n;
      if ((p & 0xFFFF) == 0 || p == data.size()) progress("write ", p, data.size());
    }
    bool ok = verify(f, off, data);
    std::printf("write %zu bytes at 0x%08x: %s in %.1f s\n", data.size(), off, ok ? "verified" : "VERIFY FAILED", secs(t0));
    return ok ? 0 : 1;
  }
  die("unknown command " + op);
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return run(argc, argv);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "\nerror: %s\n", e.what());
    return 1;
  }
}
