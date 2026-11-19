# k7_udp: k7_nic + 1 Hz UDP counter on SFP A (xc7k325t board)

Copy of `k7_nic` (PCIe Gen2 x1, BAR0 flash programmer, open-source 10GBASE-R on both SFP+
cages; see that README for the base design, pins and clocks) with a 10G MAC + UDP/IP stack
from verilog-ethernet (MIT, commit 77320a9) on the XGMII of SFP A.
`k7_nic` stays untouched as the known-good base.

SFP A sends one UDP datagram per second. Its 8-byte payload is a 64-bit counter in
**network byte order (big-endian)**: the number of datagrams sent before it (0, 1, 2, ...;
restarts at 0 when the bitstream loads). UDP checksum is 0 (allowed in IPv4), TTL 64,
frames padded to 64 bytes. The stack answers ARP for its own IP and resolves the
destination (or the gateway when off-subnet) by ARP before the first datagram
(4 tries, 0.25 s apart; a failure is counted and that second is skipped).
SFP B still transmits idle only (loopback / link check as before).

Defaults (BAR0-configurable over PCIe or JTAG-to-AXI):
local MAC 02:4B:37:00:00:6E, local IP 192.168.0.110/23, gateway 192.168.0.1,
destination 192.168.0.215 (oldgamer), UDP port 5000 -> 5000.

- `rtl/udp_counter.v` MAC (`eth_mac_10g_fifo`), `eth_axis_rx/tx`, `udp_complete_64`, sender.
  Runs on the gated 156.25 MHz TX PCS clock; MAC RX on SFP A's RX PCS clock (async FIFO).
  1 s = 156 250 000 TX PCS cycles (exact, derived from the 156.25 MHz SFP refclk).
- `rtl/udp_regs.v`  BAR0 0x080..0x0AC (user_clk), toggle-handshake CDC to the TX domain.
- `rtl/eth10g.v`    now exports SFP A's XGMII and PCS clocks/resets (ports `*_a`).
- `rtl/verilog-ethernet/` adds the MAC/IP/UDP/ARP/AXIS files. Local patch: `axis_fifo.v` and
  `axis_async_fifo.v` replace `$clog2(KEEP_WIDTH)` in a replication with a constant
  expression (Vivado 2017.4 rejects `$clog2` there).
- `sim/run_sim.sh` xsim testbench: two `udp_counter`s back to back (ARP request + reply,
  consecutive counters). Prints PASS.
- `host/k7flash.cpp` adds `reg OFFSET [VALUE]` and `udp [KEY VALUE ...]`.
- `host/udprecv.cpp` receiver: `./udprecv [PORT] [COUNT]` prints each counter with the interval
  and flags GAP / REPEAT / RESET; summary on Ctrl-C (`g++ -O2 -std=c++17 -o udprecv udprecv.cpp`).

VERSION is 0x00030000. UDP registers (byte offsets):

| off   | name       | |
|-------|------------|---|
| 0x080 | UDP_CTRL   | RW [0] enable (reset 1) |
| 0x084 | MAC_HI     | RW [15:0] MAC bits 47:32 |
| 0x088 | MAC_LO     | RW MAC bits 31:0 |
| 0x08C | LOCAL_IP   | RW (first octet in bits 31:24) |
| 0x090 | DEST_IP    | RW |
| 0x094 | GATEWAY_IP | RW |
| 0x098 | SUBNET     | RW |
| 0x09C | PORTS      | RW [31:16] source, [15:0] destination |
| 0x0A0 | PERIOD     | RW 156.25 MHz cycles between datagrams (reset 156250000, min 1000) |
| 0x0A4 | COUNT_LO   | RO datagrams sent (= next counter value), updated once per period |
| 0x0A8 | COUNT_HI   | RO |
| 0x0AC | UDP_STAT   | RO [15:0] ARP failures, [31:16] good frames received on SFP A (16-bit wrap) |

Build and load (Vivado 2017.4; volatile, flash untouched):

    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source build.tcl
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove'
    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source program.tcl -tclargs 192.168.0.215:3121
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/rescan'
    ssh shed 'cd k7_udp && sudo ./k7flash status && sudo ./k7flash udp'
    ssh shed 'sudo tcpdump -i enp3s0 -n -X -c 5 udp port 5000'
    ssh shed 'cd k7_udp && sudo ./k7flash udp dest 192.168.0.30 dport 6000'   # example change

Verified 2026-11-19 (JTAG load, remove/rescan on oldgamer, timing met WNS +0.608 ns, 11.3k LUTs):
`tcpdump -i enp3s0 -n -e udp port 5000` on oldgamer shows the ARP request/reply, then one
60-byte frame per second from 02:4b:37:00:00:6e, 192.168.0.110.5000 > 192.168.0.215.5000,
UDP length 8, payload counting up by 1 (e.g. 00..16, 00..17, 00..18), arrival spacing 1.000000 s
± 10 µs. Both SFPs stay block-locked with zero faults. The first one or two counter values
after a load can be lost (one ARP failure while the switch port comes up). oldgamer answers
with ICMP port unreachable unless something listens on UDP 5000 (e.g. `nc -ul 5000`).
