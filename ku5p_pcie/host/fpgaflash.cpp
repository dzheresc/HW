// fpgaflash: program an FPGA board's SPI configuration flash over PCIe.
// Works with the k7_pcie design (xc7k325t, 10ee:7021, ID "K7PC") and the
// ku5p_pcie design (xcku5p, 10ee:9021, ID "KUPC"). Both expose the same
// buffered SPI master in BAR0; this tool maps BAR0 through sysfs (needs root)
// and talks to the flash with it.
//
//   fpgaflash [-d BDF | -b k7|ku5p] [-c 0|1] info
//   fpgaflash ... read   FILE [OFFSET [LEN]]       (default: whole flash)
//   fpgaflash ... verify FILE [OFFSET]
//   fpgaflash ... erase  OFFSET LEN               (rounded out to sectors)
//   fpgaflash ... write  FILE [OFFSET]            (erase + program + verify)
//   fpgaflash ... status                          (registers / link)
//   fpgaflash list                                (supported boards present)
//
// -d picks a device by PCI address, -b by board; with neither, the single
// supported device present is used. -c 1 selects the second flash of a dual
// QSPI (x8) pair (design must report FEAT[0]); write_cfgmem -interface SPIx8
// produces one file per flash.
//
// Build: g++ -O2 -std=c++17 -o fpgaflash fpgaflash.cpp
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

struct Board {
  const char* name;
  uint16_t vendor, device;
  uint32_t magic;
  const char* desc;
};
constexpr Board kBoards[] = {
    {"k7", 0x10EE, 0x7021, 0x4B375043, "xc7k325t, PCIe Gen2 x1"},
    {"ku5p", 0x10EE, 0x9021, 0x4B555043, "xcku5p, PCIe4 US+"},
};
constexpr uint32_t R_ID = 0x000, R_VER = 0x004, R_STATUS = 0x008, R_CTRL = 0x00C,
                   R_XFER = 0x010, R_SCRATCH = 0x014, R_LINK = 0x018, R_CSREL = 0x01C, R_FEAT = 0x020,
                   R_TX = 0x400, R_RX = 0x800;
constexpr size_t kBuf = 1024;

[[noreturn]] void die(const std::string& m) { throw std::runtime_error(m); }

std::string readFile1(const std::string& p) {
  std::ifstream f(p);
  std::string s;
  std::getline(f, s);
  return s;
}

struct Found {
  std::string bdf;
  const Board* board;
};

// All PCI functions whose vendor:device matches a supported board.
std::vector<Found> scanDevices() {
  DIR* d = opendir("/sys/bus/pci/devices");
  if (!d) die("cannot open /sys/bus/pci/devices");
  std::vector<Found> out;
  while (dirent* e = readdir(d)) {
    if (e->d_name[0] == '.') continue;
    std::string base = std::string("/sys/bus/pci/devices/") + e->d_name;
    unsigned long v = std::strtoul(readFile1(base + "/vendor").c_str(), nullptr, 16);
    unsigned long dv = std::strtoul(readFile1(base + "/device").c_str(), nullptr, 16);
    for (const Board& b : kBoards)
      if (v == b.vendor && dv == b.device) out.push_back({e->d_name, &b});
  }
  closedir(d);
  return out;
}

const Board* boardByName(const std::string& n) {
  for (const Board& b : kBoards)
    if (n == b.name) return &b;
  die("unknown board " + n + " (k7, ku5p)");
}

// Pick the device: explicit BDF, else by board name, else the only one present.
Found findDevice(const std::string& bdf, const std::string& boardName) {
  std::string want = bdf;
  if (!want.empty() && want.find(':') == want.rfind(':')) want = "0000:" + want;  // "01:00.0"
  const Board* nb = boardName.empty() ? nullptr : boardByName(boardName);
  std::vector<Found> all = scanDevices(), hit;
  for (const Found& f : all)
    if ((want.empty() || f.bdf == want) && (!nb || f.board == nb)) hit.push_back(f);
  if (hit.empty()) {
    if (!want.empty() && !nb) {
      // explicit BDF with an unexpected ID: identify it by the ID register later
      return {want, nullptr};
    }
    die("no supported device found (load the bitstream, then rescan the bus)");
  }
  if (hit.size() > 1) {
    std::string m = "several devices found, pick one with -d or -b:";
    for (const Found& f : hit) m += std::string("\n  ") + f.bdf + "  " + f.board->name;
    die(m);
  }
  return hit[0];
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
  Spi(const Bar& b, uint32_t magic) : b_(b), magic_(magic) {}

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
      if (w == 0xFFFFFFFF && b_.rd(R_ID) != magic_) die("device stopped responding");
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
  uint32_t magic_;
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
  uint8_t rdfsr() { return s_.xfer({0x70}, 2)[1]; }
  bool micron() const { return id_[0] == 0x20; }
  bool busy() {
    // Micron MT25Q: the flag status register must be polled (required on the
    // stacked-die 1 Gb / 2 Gb parts); FSR bit 7 = ready.
    if (micron()) return !(rdfsr() & 0x80) || (rdsr() & 0x01);
    return rdsr() & 0x01;
  }
  void waitWip(double timeoutSec) {
    auto t0 = std::chrono::steady_clock::now();
    while (busy()) {
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
    if (micron()) {
      uint8_t f = rdfsr();
      if (f & 0x32) {            // erase / program / protection error
        s_.xfer({0x50}, 1);      // clear flag status register
        char m[64];
        std::snprintf(m, sizeof m, " error reported by flash (FSR %02X)", f);
        die(std::string(what) + m);
      }
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

const char* partName(const uint8_t* id) {
  struct P { uint8_t m, t, c; const char* n; };
  static const P kParts[] = {
      {0x01, 0x02, 0x19, "Spansion/Cypress S25FL256S (256 Mbit, 3.3 V)"},
      {0x01, 0x02, 0x20, "Spansion/Cypress S25FL512S (512 Mbit, 3.3 V)"},
      {0x01, 0x20, 0x18, "Spansion/Cypress S25FL128S (128 Mbit, 3.3 V)"},
      {0x20, 0xBA, 0x18, "Micron N25Q128A13 / MT25QL128 (128 Mbit, 3.3 V)"},
      {0x20, 0xBB, 0x18, "Micron MT25QU128 / N25Q128A11 (128 Mbit, 1.8 V)"},
      {0x20, 0xBA, 0x19, "Micron MT25QL256 (256 Mbit, 3.3 V)"},
      {0x20, 0xBA, 0x20, "Micron MT25QL512 (512 Mbit, 3.3 V)"},
      {0x20, 0xBA, 0x21, "Micron MT25QL01G (1 Gbit, 3.3 V)"},
      {0x20, 0xBA, 0x22, "Micron MT25QL02G (2 Gbit, 3.3 V)"},
      {0x20, 0xBB, 0x19, "Micron MT25QU256 (256 Mbit, 1.8 V)"},
      {0x20, 0xBB, 0x20, "Micron MT25QU512 (512 Mbit, 1.8 V)"},
      {0x20, 0xBB, 0x21, "Micron MT25QU01G (1 Gbit, 1.8 V)"},
      {0x20, 0xBB, 0x22, "Micron MT25QU02G (2 Gbit, 1.8 V)"},
      {0xC2, 0x25, 0x39, "Macronix MX25U25635F (256 Mbit, 1.8 V)"},
      {0xC2, 0x25, 0x3A, "Macronix MX25U51245G (512 Mbit, 1.8 V)"},
      {0xC2, 0x20, 0x19, "Macronix MX25L25645G (256 Mbit, 3.3 V)"},
      {0x9D, 0x70, 0x19, "ISSI IS25WP256 (256 Mbit, 1.8 V)"},
      {0x9D, 0x60, 0x19, "ISSI IS25LP256 (256 Mbit, 3.3 V)"},
      {0xEF, 0x40, 0x19, "Winbond W25Q256 (256 Mbit, 3.3 V)"},
      {0xEF, 0x80, 0x19, "Winbond W25Q256JW (256 Mbit, 1.8 V)"},
  };
  for (const P& p : kParts)
    if (id[0] == p.m && id[1] == p.t && id[2] == p.c) return p.n;
  return "unknown (sizes/opcodes from SFDP)";
}

int run(int argc, char** argv) {
  std::string bdf, boardName;
  int cs = 0;
  int i = 1;
  while (i + 1 < argc && argv[i][0] == '-') {
    std::string o = argv[i];
    if (o == "-d") bdf = argv[i + 1];
    else if (o == "-b") boardName = argv[i + 1];
    else if (o == "-c") cs = int(num(argv[i + 1]));
    else die("unknown option " + o);
    i += 2;
  }
  if (i >= argc) {
    std::fprintf(stderr,
                 "usage: fpgaflash [-d BDF | -b k7|ku5p] [-c 0|1] info|status|read|verify|erase|write ...\n"
                 "       fpgaflash list\n");
    return 2;
  }
  std::string op = argv[i++];
  if (op == "list") {
    for (const Found& f : scanDevices()) std::printf("%s  %-5s %s\n", f.bdf.c_str(), f.board->name, f.board->desc);
    return 0;
  }
  Found dev = findDevice(bdf, boardName);
  Bar bar(dev.bdf);
  uint32_t idreg = bar.rd(R_ID);
  if (!dev.board)
    for (const Board& b : kBoards)
      if (idreg == b.magic) dev.board = &b;
  if (!dev.board || idreg != dev.board->magic) {
    char m[96];
    std::snprintf(m, sizeof m, "unexpected ID register %08x at %s (wrong bitstream?)", idreg, dev.bdf.c_str());
    die(m);
  }
  // FEAT is a newer register; on older K7 bitstreams the address reads as 0.
  uint32_t feat = bar.rd(R_FEAT);
  if (cs < 0 || cs > 1 || (cs == 1 && !(feat & 1))) die("this design has no second flash (-c 1)");

  if (op == "status") {
    uint32_t l = bar.rd(R_LINK);
    static const char* kRate[] = {"2.5GT/s", "5.0GT/s", "8.0GT/s", "16GT/s"};
    std::printf("device %s (%s)  ID %08x  VER %08x  STATUS %08x  CTRL %08x  FEAT %08x\n", dev.bdf.c_str(),
                dev.board->name, idreg, bar.rd(R_VER), bar.rd(R_STATUS), bar.rd(R_CTRL), feat);
    // LINK: [15] up, [14:12] width code (0=x1 1=x2 2=x4 3=x8), [9:8] rate, [5:0] LTSSM
    std::printf("link up %u  LTSSM 0x%02x  rate %s  width x%u\n", (l >> 15) & 1, l & 0x3F,
                kRate[(l >> 8) & 3], 1u << ((l >> 12) & 7));
    return 0;
  }

  Spi spi(bar, dev.board->magic);
  bar.wr(R_CSREL, 1);
  {
    // select the flash; keep the SCK divider
    uint32_t c = bar.rd(R_CTRL);
    bar.wr(R_CTRL, (c & 0xFF) | (uint32_t(cs) << 8));
    if (cs && !((bar.rd(R_CTRL) >> 8) & 1)) die("flash select did not stick");
  }
  Flash f(spi);
  const uint8_t* id = f.jedec();

  if (op == "info") {
    std::printf("device     %s (%s), flash %d\n", dev.bdf.c_str(), dev.board->name, cs);
    std::printf("JEDEC ID   %02X %02X %02X\n", id[0], id[1], id[2]);
    std::printf("size       %u bytes (%u Mbit)\n", f.size(), f.size() >> 17);
    std::printf("erase      %u KiB, opcode 0x%02X\n", f.erase().size >> 10, f.erase().op);
    std::printf("addressing %s\n", f.addr4() ? "4-byte opcodes (0x13/0x12)" : "3-byte");
    std::printf("SR1        %02X\n", f.rdsr());
    if (f.micron()) std::printf("FSR        %02X\n", f.rdfsr());
    std::printf("part       %s\n", partName(id));
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
