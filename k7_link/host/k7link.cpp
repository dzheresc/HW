// k7link: link status and counters of the k7_link design (both SFP+ ports), read over PCIe.
// Build: g++ -O2 -std=c++23 -o k7link k7link.cpp      Run: sudo ./k7link [seconds between prints]
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

namespace {

constexpr uint32_t kMagic = 0x4B375043;    // "K7PC"
constexpr uint32_t kVersion = 0x00050000;  // k7_link
constexpr uint32_t kEthStat = 0x020;
constexpr uint32_t kEthRates = 0x024;

uint32_t ReadHex(const std::filesystem::path& path) {
  std::ifstream in(path);
  uint32_t value = 0;
  in >> std::hex >> value;
  return value;
}

std::filesystem::path FindDevice() {
  for (const auto& entry : std::filesystem::directory_iterator("/sys/bus/pci/devices")) {
    if (ReadHex(entry.path() / "vendor") == 0x10EE && ReadHex(entry.path() / "device") == 0x7022) {
      return entry.path();
    }
  }
  return {};
}

void PrintPort(const volatile uint32_t* bar, char name, uint32_t base, uint32_t stat_shift,
               uint32_t rates) {
  const auto rd = [bar](uint32_t offset) { return bar[offset / 4]; };
  const uint32_t st = rd(kEthStat) >> stat_shift;
  const uint32_t ip = rd(base + 0x20);
  std::printf("SFP %c %u.%u.%u.%u  %s  (block lock %u, high BER %u, local faults/s %u, remote faults/s %u)\n",
              name, ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255,
              (rd(base + 0x2C) & 1) ? "LINK UP" : "link down", st & 1, (st >> 1) & 1,
              rd(rates + 4), rd(rates + 8));
  std::printf("  rx good %u, bad FCS %u, bad frames %u, fifo drops %u | replies: arp %u, ping %u, udp %u | tx frames %u\n",
              rd(base), rd(base + 4), rd(base + 8), rd(base + 12), rd(base + 16), rd(base + 20),
              rd(base + 24), rd(base + 28));
}

}  // namespace

int main(int argc, char** argv) {
  const int interval = argc > 1 ? std::atoi(argv[1]) : 0;
  const auto device = FindDevice();
  if (device.empty()) {
    std::fprintf(stderr, "no 10ee:7022 device found\n");
    return 1;
  }
  std::ofstream(device / "enable") << "1";  // no driver is bound: turn memory decoding on
  const int fd = open((device / "resource0").c_str(), O_RDWR | O_SYNC);
  if (fd < 0) {
    std::perror("open resource0 (run as root?)");
    return 1;
  }
  void* map = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (map == MAP_FAILED) {
    std::perror("mmap BAR0");
    return 1;
  }
  const auto* bar = static_cast<const volatile uint32_t*>(map);
  if (bar[0] != kMagic || bar[1] != kVersion) {
    std::fprintf(stderr, "not k7_link: ID %08x VERSION %08x\n", bar[0], bar[1]);
    return 1;
  }
  do {
    PrintPort(bar, 'A', 0x200, 16, kEthRates + 0x08);
    PrintPort(bar, 'B', 0x240, 24, kEthRates + 0x14);
    std::fflush(stdout);
    if (interval > 0) sleep(interval);
  } while (interval > 0);
  return 0;
}
