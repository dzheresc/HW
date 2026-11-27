// hrtool: exercise k7_host_ram. Needs root and no IOMMU (bus address = physical address).
//   hrtool status            registers only, no DMA
//   hrtool test [PAGES]      PAGES x 2 MB hugepages (default 64, max 512): data both ways, refusal, canaries, rates
// Only 10ee:7022 with VERSION 0x0006xxxx is touched: other K7 images share the PCI ID.
// Every other allocated hugepage is a canary that is never mapped in the FPGA.
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <string>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <vector>
using u32 = uint32_t; using u64 = uint64_t;
static constexpr size_t HP = 2u << 20; static constexpr u32 LPP = HP / 128;
[[noreturn]] static void die(const std::string& m) { fprintf(stderr, "hrtool: %s%s%s\n", m.c_str(), errno ? ": " : "", errno ? strerror(errno) : ""); exit(1); }
static std::string line1(const std::string& p) { std::ifstream f(p); std::string s; std::getline(f, s); return s; }
static u64 now() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000ull + t.tv_nsec; }
static volatile u32* B; static std::string bdf; static int cfgfd = -1; static bool stopped; static long oldhp = -1;
static u32 rd(u32 o) { return B[o / 4]; }
static void wr(u32 o, u32 v) { B[o / 4] = v; }
static void bme(bool on) { uint16_t c; if (pread(cfgfd, &c, 2, 4) != 2) die("config read"); c = on ? c | 6 : (c | 2) & ~4; if (pwrite(cfgfd, &c, 2, 4) != 2) die("config write"); }
// Order matters: refuse new accesses, wait for outstanding ones, then bus mastering off, and only then may memory be freed.
static bool quiesce() {
  wr(0x108, 0); u64 t = now(); while ((rd(0x104) & 9) != 8 && now() - t < 1000000000ull) usleep(1000);
  bool idle = (rd(0x104) & 9) == 8; bme(false); wr(0x100, 1u << 31); return idle;
}
static void cleanup() { if (B && !stopped) { stopped = true; if (!quiesce()) fprintf(stderr, "warning: core not idle at exit (bus mastering is off)\n"); usleep(100000); } if (oldhp >= 0) { if (FILE* f = fopen("/proc/sys/vm/nr_hugepages", "w")) { fprintf(f, "%ld\n", oldhp); fclose(f); } } }
static volatile sig_atomic_t sig; static void onsig(int) { sig = 1; }
static void openDev() {
  DIR* d = opendir("/sys/bus/pci/devices"); if (!d) die("pci"); while (dirent* e = readdir(d)) { std::string b = std::string("/sys/bus/pci/devices/") + e->d_name; if (line1(b + "/vendor") == "0x10ee" && line1(b + "/device") == "0x7022") bdf = e->d_name; } closedir(d);
  errno = 0; if (bdf.empty()) die("no 10ee:7022"); std::string b = "/sys/bus/pci/devices/" + bdf; if (access((b + "/iommu_group").c_str(), F_OK) == 0) { errno = 0; die("device is behind an IOMMU"); }
  errno = 0; cfgfd = open((b + "/config").c_str(), O_RDWR); if (cfgfd < 0) die("config"); bme(false);
  int f = open((b + "/resource0").c_str(), O_RDWR | O_SYNC); if (f < 0) die("resource0"); void* p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, f, 0); if (p == MAP_FAILED) die("mmap BAR0"); volatile u32* m = (volatile u32*)p;
  u32 id = m[0], ver = m[1]; errno = 0; if (id != 0x4B375043 || ver >> 16 != 6) { char s[128]; snprintf(s, sizeof s, "not k7_host_ram (ID %08x VERSION %08x): nothing written to its registers", id, ver); die(s); } B = m;
}
static u64 phys(const void* v) { static int fd = open("/proc/self/pagemap", O_RDONLY); u64 e; if (fd < 0 || pread(fd, &e, 8, (uintptr_t)v / 4096 * 8) != 8) die("pagemap"); errno = 0; if (!(e >> 63) || !(e & ((1ull << 55) - 1))) die("no physical address (root?)"); return (e & ((1ull << 55) - 1)) * 4096; }
static u64 pat(u32 l, u32 k, u32 s) { return (u64)(s ^ (l << 9)) << 32 | (u64)l << 9 | k << 5 | 0x15; }
struct Res { double us, gbs, mlps; u32 errs, rderr, got, lmin, lmax; double lavg; };
static Res run(bool w, bool rnd, int span, u32 base, u32 cnt, u32 seed, u32 win) {
  wr(0x118, span); wr(0x11C, base); wr(0x120, cnt); wr(0x124, seed); wr(0x128, win); (void)rd(0x104); wr(0x100, 1 | w << 1 | rnd << 2); u64 t = now();
  while (rd(0x104) & 1) { if (sig) { errno = 0; die("interrupted"); } if (now() - t > 60000000000ull) { errno = 0; die("tester did not finish"); } usleep(200); }
  u64 c = rd(0x134) | (u64)rd(0x138) << 32, ls = rd(0x144) | (u64)rd(0x148) << 32; Res r; r.us = c * .004; r.gbs = cnt * 128.0 / (c * 4.0); r.mlps = cnt / r.us; r.errs = rd(0x12C); r.rderr = rd(0x130); r.got = rd(0x164); r.lmin = rd(0x13C); r.lmax = rd(0x140); r.lavg = cnt ? (double)ls / cnt : 0; return r;
}
static void status() { printf("%s VERSION %08x LINK %08x STAT %x npages %u reads %u writes %u refused %u badcpl %u unexpected %u\n", bdf.c_str(), rd(4), rd(0x18), rd(0x104), rd(0x108), rd(0x14C), rd(0x150), rd(0x154), rd(0x158), rd(0x15C)); }
static int fails; static void check(const char* n, bool ok) { printf("%s %s\n", ok ? "PASS" : "FAIL", n); fails += !ok; fflush(stdout); }
int main(int c, char** v) {
  std::string op = c > 1 ? v[1] : ""; if (op != "status" && op != "test") { fprintf(stderr, "hrtool status | test [PAGES]\n"); return 2; }
  openDev(); if (op == "status") { status(); B = nullptr; return 0; }
  int n = c > 2 ? atoi(v[2]) : 64, sp = 0; errno = 0; if (n < 1 || n > 512 || (n & (n - 1))) die("PAGES must be a power of two, 1..512"); while ((LPP * (u32)n) >> (sp + 1)) sp++; const u32 NL = LPP * n;
  struct sigaction sa{}; sa.sa_handler = onsig; sigaction(SIGINT, &sa, 0); sigaction(SIGTERM, &sa, 0); sigaction(SIGHUP, &sa, 0);
  long fr = atol(line1("/sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages").c_str()), tot = atol(line1("/proc/sys/vm/nr_hugepages").c_str()); atexit(cleanup);
  if (fr < 2 * n) { oldhp = tot; FILE* f = fopen("/proc/sys/vm/nr_hugepages", "w"); if (!f) die("nr_hugepages"); fprintf(f, "%ld\n", tot + 2 * n - fr); fclose(f); }
  uint8_t* M = (uint8_t*)mmap(0, 2 * n * HP, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE | MAP_LOCKED, -1, 0); if (M == MAP_FAILED) die("hugepages");
  auto pg = [&](u32 i) { return (u64*)(M + 2 * (size_t)i * HP); }; auto can = [&](u32 i) { return (u64*)(M + (2 * (size_t)i + 1) * HP); };
  memset(M, 0, 2 * n * HP); for (int i = 0; i < n; i++) for (size_t k = 0; k < HP / 8; k++) can(i)[k] = 0xC0DEC0DE00000000ull ^ (i * 1000003ull + k);
  wr(0x100, 1u << 31); wr(0x108, 0); wr(0x10C, 0); for (int i = 0; i < n; i++) { u64 a = phys(pg(i)); if (a & (HP - 1)) { errno = 0; die("hugepage not aligned"); } wr(0x110, (u32)a); wr(0x114, a >> 32); }
  bme(true); wr(0x108, n); wr(0x100, 0); status();
  for (int r = 0; r < 2; r++) {
    u32 s = 0x1000 + r; Res a = run(1, r, sp, 0, NL, s, 16); bool ok = true; for (u32 l = 0; l < NL && ok; l++) for (int k = 0; k < 16; k++) if (pg(l / LPP)[(l % LPP) * 16 + k] != pat(l, k, s)) { printf("  line %u word %d: %016llx\n", l, k, (unsigned long long)pg(l / LPP)[(l % LPP) * 16 + k]); ok = false; break; }
    printf("%s write %.2f GB/s\n", r ? "random" : "sequential", a.gbs); check(r ? "FPGA random writes seen by CPU" : "FPGA sequential writes seen by CPU", ok);
    s += 0x100; for (u32 l = 0; l < NL; l++) for (int k = 0; k < 16; k++) pg(l / LPP)[(l % LPP) * 16 + k] = pat(l, k, s);
    for (u32 w : {1u, 2u, 4u, 8u, 16u}) { Res b = run(0, r, sp, 0, w == 1 ? (NL < 200000 ? NL : 200000) : NL, s, w); printf("%s read window %2u: %.2f GB/s %.2f M lines/s, latency min %.0f avg %.0f max %.0f ns\n", r ? "random" : "sequential", w, b.gbs, b.mlps, b.lmin * 4.0, b.lavg * 4, b.lmax * 4.0); if (b.errs || b.rderr) printf("  errs %u rd_err %u first bad line %u\n", b.errs, b.rderr, rd(0x160)); check("CPU data read by FPGA", !b.errs && !b.rderr); }
  }
  { pg(0)[16 * 5 + 3] ^= 1; Res b = run(0, 0, 10, 0, 1024, 0x1101, 16); check("one flipped bit is detected", b.errs == 1 && rd(0x160) == 5); pg(0)[16 * 5 + 3] ^= 1; }
  if (n < 512) { u32 rf = rd(0x154); run(1, 0, 10, NL, 1024, 7, 16); Res b = run(0, 0, 10, NL, 1024, 7, 16); check("out-of-range accesses refused", rd(0x154) - rf == 2048 && b.rderr == 1024); }
  { wr(0x108, 0); u32 rf = rd(0x154); run(1, 0, 10, 0, 64, 9, 16); check("npages=0 refuses everything", rd(0x154) - rf == 64); }
  bool ok = true; for (int i = 0; i < n && ok; i++) for (size_t k = 0; k < HP / 8; k++) if (can(i)[k] != (0xC0DEC0DE00000000ull ^ (i * 1000003ull + k))) { ok = false; break; } check("canary pages untouched", ok);
  status(); check("no bad/unexpected completions, not fatal", !rd(0x158) && !rd(0x15C) && !(rd(0x104) & 4));
  stopped = true; bool q = quiesce(); check("idle before release", q); usleep(100000); munmap(M, 2 * n * HP); printf("%s (%d failed)\n", fails ? "FAILED" : "ALL PASSED", fails); return fails != 0;
}
