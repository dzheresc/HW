// udprecv: listen for the K7 counter datagrams (k7_udp) and report gaps.
// Each datagram carries a 64-bit big-endian counter that increments by 1.
//
//   udprecv [PORT] [COUNT]     (default port 5000, run forever)
//
// Prints one line per datagram: arrival time, sender, counter, interval since the
// previous one; flags gaps (missing values), repeats and backwards jumps
// (e.g. after the FPGA is reloaded). Ctrl-C prints a summary.
// Build: g++ -O2 -std=c++17 -Wall -o udprecv udprecv.cpp
#include <arpa/inet.h>
#include <cinttypes>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile sig_atomic_t stop = 0;

int main(int argc, char** argv) {
  int port = argc > 1 ? std::atoi(argv[1]) : 5000;
  long limit = argc > 2 ? std::atol(argv[2]) : -1;

  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) { perror("socket"); return 1; }
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof a) < 0) { perror("bind"); return 1; }

  struct sigaction sa{};
  sa.sa_handler = [](int) { stop = 1; };
  sigaction(SIGINT, &sa, nullptr);   // no SA_RESTART: recvfrom returns EINTR
  sigaction(SIGTERM, &sa, nullptr);

  std::printf("listening on UDP %d\n", port);
  std::fflush(stdout);
  bool have = false;
  uint64_t last = 0, received = 0, missing = 0, bad = 0, resets = 0;
  timespec prev{};
  while (!stop && (limit < 0 || long(received) < limit)) {
    unsigned char buf[2048];
    sockaddr_in src{};
    socklen_t sl = sizeof src;
    ssize_t n = recvfrom(fd, buf, sizeof buf, 0, reinterpret_cast<sockaddr*>(&src), &sl);
    if (n < 0) break;   // EINTR on Ctrl-C
    timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    char ts[32];
    tm lt;
    localtime_r(&now.tv_sec, &lt);
    std::strftime(ts, sizeof ts, "%H:%M:%S", &lt);
    char from[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &src.sin_addr, from, sizeof from);

    if (n != 8) {
      ++bad;
      std::printf("%s.%06ld %s:%u  unexpected length %zd\n", ts, now.tv_nsec / 1000, from,
                  ntohs(src.sin_port), n);
      continue;
    }
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | buf[i];   // network byte order
    ++received;

    double dt = have ? (now.tv_sec - prev.tv_sec) + (now.tv_nsec - prev.tv_nsec) * 1e-9 : 0.0;
    char note[96] = "";
    if (have) {
      if (v == last + 1) {
      } else if (v > last + 1) {
        missing += v - last - 1;
        std::snprintf(note, sizeof note, "  GAP: %" PRIu64 " missing (%" PRIu64 "..%" PRIu64 ")",
                      v - last - 1, last + 1, v - 1);
      } else if (v == last) {
        std::snprintf(note, sizeof note, "  REPEAT");
      } else {
        ++resets;
        std::snprintf(note, sizeof note, "  RESET: went back from %" PRIu64, last);
      }
    }
    if (have)
      std::printf("%s.%06ld %s:%u  counter %" PRIu64 "  dt %.6f s%s\n", ts, now.tv_nsec / 1000, from,
                  ntohs(src.sin_port), v, dt, note);
    else
      std::printf("%s.%06ld %s:%u  counter %" PRIu64 "  (first)\n", ts, now.tv_nsec / 1000, from,
                  ntohs(src.sin_port), v);
    std::fflush(stdout);
    have = true;
    last = v;
    prev = now;
  }
  std::printf("summary: received %" PRIu64 ", missing %" PRIu64 ", resets %" PRIu64
              ", bad length %" PRIu64 "\n", received, missing, resets, bad);
  close(fd);
  return 0;
}
