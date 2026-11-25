# k7_link: test both 10G links (xc7k325t board)

Both SFP+ cages run 10GBASE-R (license-free PCS from `k7_cap`) with a verilog-ethernet 10G MAC
and a small line-rate responder. The card only ever **replies**; it never starts traffic.

| port | cage | connected to | IP | MAC |
|---|---|---|---|---|
| A | SFP A (GTX X0Y7) | switch | 192.168.0.110 | 02:4B:37:00:00:6E |
| B | SFP B (GTX X0Y6) | other host, direct DAC | 10.10.0.1 | 02:4B:37:00:01:01 |

Answered: ARP requests for the port's IP, ping (unicast, up to a 9000-byte MTU), UDP to port 7
(datagram comes back, ports swapped). Everything else is dropped. Not checked: IP header and
ICMP/UDP checksums (the FCS is). No gateway, no ARP requests: replies go to the MAC that asked.

Kept from k7_cap: PCIe Gen2 x4 (10ee:7022), BAR0 flash programmer and REBOOT, JTAG-to-AXI.
Dropped: packet capture / DMA. VERSION is 0x00050000; `k7cap` does not work on this bitstream.

LEDs: 0 heartbeat, 1 PCIe link, 2 A link, 3 A activity, 4 B link, 5 B activity. "Link" = block
lock, low BER, and no local/remote faults in the last second.

BAR0 (read-only): port A at 0x200, port B at 0x240: +00 rx good, +04 bad FCS, +08 bad frames,
+0C RX FIFO drops, +10 ARP replies, +14 ping replies, +18 UDP replies, +1C TX frames, +20 IP,
+24/+28 MAC, +2C link.

## Build and simulate (Vivado 2024.2)

    sh sim/run_sim.sh                                                       # prints PASS
    C:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source build.tcl    # build/top.bit, build/top.bin

`ip/*.xci` came from k7_cap (2017.4) and were upgraded once with `upgrade_ip.tcl`.

## Test

Host on port B, once (any free address in 10.10.0.0/24; replace `<iface>`):

    sudo ip addr add 10.10.0.2/24 dev <iface> && sudo ip link set <iface> up

Then `ping 192.168.0.110` (any host on the switch's LAN) and `ping 10.10.0.1` (port B host).
Load: `sudo ping -f -s 1472 10.10.0.1`. Counters on the shed PC: `sudo ~/k7_link/k7link 1`.

Built 2026-11-25 (2024.2): WNS +0.418 ns, WHS +0.040 ns, 12.6k LUTs, 24.5 BRAM. Simulation PASS. Not yet run on hardware.

## Load

Volatile (JTAG, flash untouched; a `fpgaflash -b k7 reboot` or power cycle returns to the flash image):

    ssh shed 'echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove'
    C:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source C:\develop\k7_link\program.tcl
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/rescan'

To flash instead: `sudo ~/ku5p_pcie/bin/fpgaflash -b k7 write ~/k7_link/top.bin`, then `... -b k7 reboot`.
Back to capture: write `~/k7_cap/top_reboot.bin` the same way.
