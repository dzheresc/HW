# k7_cap_ab: 10G packet capture on both SFP+ cages to host hugepages (xc7k325t board)

Variant of `k7_cap` with a second capture input. Every frame received on **SFP A** (DAC to the
switch) and/or **SFP B** (DAC to zlab `ens6`) is timestamped, buffered on chip per port, merged
record by record, and written by DMA (PCIe Gen2 x4) into **one ring of 2 MB hugepages** in host
memory. Each record says which cage it came from. Both cages transmit XGMII idle only: nothing is
ever sent on the wire. Everything else is as in k7_cap: the BAR0 flash programmer, **REBOOT**
(`fpgaflash -b k7 reboot`), JTAG-to-AXI, the 10G status registers, and PCIe ID 10ee:7022.
**VERSION 0x00070000.** `k7_cap` stays untouched as the single-port base.

## Data path

```
SFP A RX PCS clock                                   PCIe user clock (250 MHz)
  axis_xgmii_rx_64 ─┐                                ┌──────────────┐
  cap_testgen (A) ──┴─> cap_ingress ─> data 256 KB ──┤              │
                                       meta 4096 ────┤ cap_merge    ├─> cap_dma ─> MWr TLPs ─> pcie_7x
SFP B RX PCS clock                                   │ whole records│   (serializer, ring writer,
  axis_xgmii_rx_64 ─┐                                │ round robin  │    head writeback, tail doorbell)
  cap_testgen (B) ──┴─> cap_ingress ─> data 256 KB ──┤              │
                                       meta 4096 ────┤              │
                                                     └──────────────┘
```

- `rtl/cap_port.v`  one capture input: MAC receiver (verilog-ethernet, keep_fcs patch), test
  generator, ingress, data/meta FIFOs, counter snapshots. It tags each meta entry with its port.
- `rtl/cap_merge.v` passes whole records (meta entry + ceil(len/8) data words) from the two FIFO
  pairs to the DMA serializer. When both ports have records waiting it alternates between them.
  There are no idle cycles between records.
- `rtl/cap_top.v`   both ports, merge, DMA, registers; one timestamp counter for both ports.
- `rtl/cap_dma.v`, `cap_ingress.v`, `afifo.v` as in k7_cap. The only change: the DMA puts the
  port into record byte 13.
- `rtl/eth10g.v`    from k7_link (exports SFP B's XGMII as well); `rtl/top.v` wires both cages.
- `host/k7cap.cpp`  capture tool (pcap / pcapng). `host/k7flash.cpp` is as in k7_cap.
- `sim/run_sim.sh`  xsim testbench with two XGMII sources on slightly different clocks (see below).
- `test/`           the hardware tests below: `pings_ab.sh`, `flood_b.sh`, `cmp_pcapng.py`.

**Bandwidth.** One port at 10G line rate fits PCIe x4. k7_cap measured 17.4 Mpps of 60-byte
frames (~1.3 GB/s of DMA) with 0 drops. Both ports at full line rate (up to 2.5 GB/s of
records) do not fit. Frames that do not fit are dropped whole and counted per port. Each port's
records carry the number of frames dropped on that port just before them, so every gap is
accounted for. That field saturates at 65535: a longer gap (a host stalled for more than about
80 ms at line rate) shows as 65535, and DROP_FRAMES has the exact total. A short `-s`
(snaplen) makes both ports fit when only headers are needed.

## Ring and record format

As k7_cap: 2 MB hugepages, block table, head writeback, TAIL doorbell. Records are 8-byte
aligned, little endian:

| bytes | field |
|---|---|
| 0..7   | timestamp, 6.4 ns ticks (one counter for both ports) |
| 8..9   | captured length (bytes stored, <= snaplen) |
| 10..11 | wire length (bytes from the MAC; includes the FCS if kept) |
| 12     | flags: [0] FCS/framing error [1] truncated [2] FCS included [3] aborted (link reset mid-frame) |
| 13     | **port: 0 = SFP A, 1 = SFP B** (was 0 in k7_cap) |
| 14..15 | frames dropped **on that port** just before this record (saturates at 65535) |
| 16..   | frame data, padded to a multiple of 8 |

## Registers (BAR0 0x100..0x1FF; also over JTAG-to-AXI)

As k7_cap, with these changes:

| off | name | |
|---|---|---|
| 0x100 | CTRL | RW [0] enable [1] reset (held while 1) [2] keep bad frames [3] keep FCS [4] test generators |
| 0x104 | STATUS | RO [0] bus master enable [1] DMA running [4:2] MPS [5] SFP A block lock **[6] SFP B block lock** [25:16] prefetch level |
| 0x144 | FIFO_MAX | RO highest data FIFO level since reset: [15:0] port A, **[31:16] port B** (words; 32768 each) |
| 0x148 | **PORTS** | RW [0] capture SFP A [1] capture SFP B. Reset 1 (A only), so the old k7cap still works |
| 0x150..0x170, 0x190 | port A counters | RO 64-bit: RX_FRAMES, RX_BYTES, CAP_FRAMES, DROP_FRAMES, BAD_FRAMES, TG_SEQ |
| 0x178/0x180/0x188 | RECORDS / TLPS / STALLS | RO 64-bit, both ports together |
| 0x1A0..0x1C8 | **port B counters** | RO 64-bit: RX_FRAMES 0x1A0, RX_BYTES 0x1A8, CAP_FRAMES 0x1B0, DROP_FRAMES 0x1B8, BAD_FRAMES 0x1C0, TG_SEQ 0x1C8 |

Read the low word of a 64-bit register first; that latches the high word. The port counters
update every 105 us. Change SNAPLEN, TG_CFG and the CTRL keep bits only while enable is 0.
PORTS may change at any time; each port decides at the first word of a frame.

## Host tool

Needs root (sysfs BAR mmap, config space, `/proc/self/pagemap`) and no IOMMU (oldgamer has
none). It reserves its 2 MB hugepages itself (`/proc/sys/vm/nr_hugepages`) and maps them with
`MAP_HUGETLB | MAP_LOCKED`. The ring defaults to 256 MB = 128 hugepages (`-m`, up to 1 GB).

    g++ -O2 -std=c++17 -pthread -o k7cap k7cap.cpp
    sudo ./k7cap -p ab -w cap.pcapng -c 3     # both cages, until Ctrl-C, RX thread on core 3
    sudo ./k7cap -p b -w zlab.pcap            # one cage: classic pcap works too
    sudo ./k7cap -p ab -t 5 --testgen 60,10 --check   # both generators, verify sequences

- `-p a|b|ab` picks the cages (default ab).
- `-w FILE.pcapng` writes pcapng with one interface per cage (`sfp_a` = 0, `sfp_b` = 1,
  nanosecond timestamps):
  - drops before a packet go in `epb_dropcount` (at most 65535, as in the record)
  - bad-FCS frames (with `--keep-bad`) set the CRC-error bit in `epb_flags`
  - `if_fcslen` is 4 with `--keep-fcs`
- Any other file name writes classic pcap, which has no port field, so it needs a single port.
- The other options are as in k7_cap: `-s SNAPLEN`, `-m RING_MB`, `-n COUNT`, `-t SECONDS`,
  `--keep-bad`, `--keep-fcs`, `-q`.
- The tool prints statistics per port, once a second and at the end. The final line says how
  many drops were reported inside records; the rest came after the last record, or above the
  65535 cap (it names the number of capped records).
- `--check` (test generators) compares every sequence number with the drops the record
  reports. A gap above a capped 65535 is consistent and counted as "gaps over 65535 drops",
  not as an error.
- It refuses any bitstream other than VERSION 0x0007xxxx. The k7_cap tool on this bitstream
  captures port A only (PORTS resets to A).
- To start it in the background over ssh before sending test traffic, make
  `nohup sudo ./k7cap ... > log 2>&1 < /dev/null &` a command of its own. In
  `cd dir && nohup ... &` the whole `&&` list runs in a background subshell that keeps the ssh
  session open, so ssh returns only after the capture has ended.

## Simulation

`sim/run_sim.sh` (Vivado 2024.2 xsim) feeds XGMII frames with real CRCs into both ports, on
clocks 94 ppm apart. Starts are on lanes 0 and 4, and some frames have a bad FCS. The TLPs go
into a memory model with random backpressure. A host-style consumer checks every record byte
for byte against the frames sent on its port and accounts for every reported drop.

1. Both ports, FCS stripped, bad frames discarded: every good frame arrives.
2. Both ports, FCS and bad frames kept, snaplen 128, slow host: the ring fills and both ports
   drop. On each port, records + FPGA drops = frames sent.
3. Both generators at line rate (2 x 14.2 Mframes/s, more than the DMA path carries): each
   port's sequence gaps equal its drops, and the merge serves both ports equally.
4. Port B only, with frames on both ports: nothing from port A appears.
5. Port A's generator alone at line rate: no drops, as in k7_cap.

Last run 2026-11-27: PASS, all five phases. xsim compiles the design with gcc. On a Linux
machine without gcc, run it in a container that has gcc, with /opt/Xilinx mounted read-only.

## Build and load (Vivado 2024.2)

    vivado -mode batch -source build.tcl        # build/top.bit, build/top.ltx, build/top.bin
    # JTAG load (volatile; flash untouched), on oldgamer:
    echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove
    vivado -mode batch -source program.tcl -tclargs localhost:3121
    echo 1 | sudo tee /sys/bus/pci/rescan
    sudo ./k7flash status                       # VER 00070000, both SFPs locked
    # back to the flash image:
    sudo ~/ku5p_pcie/bin/fpgaflash -b k7 reboot

The IP in `ip/` is the 2024.2 (rev 23) set from k7_cap. Rerun `upgrade_ip.tcl` if Vivado
reports locked IP.

## Verified on hardware (2026-11-27, JTAG load, oldgamer)

**Build:** 21 min on the agentic VM (one NUMA node). Timing met (WNS +0.202 ns, WHS +0.033 ns),
0 critical warnings. Uses 12.7k LUTs, 18.8k FFs and 165.5 BRAM tiles (37%).

**Load:** the card came up as 02:00.0 10ee:7022, Gen2 x4, VER 0x00070000, both SFPs locked. The
flash still holds k7_cap. `fpgaflash -b k7 reboot` from this bitstream brought the card back
to it in 2.5 s.

**Flash programmer over BAR0** (`k7flash`):
- 64 KB written and verified at 0x0A00000 in 0.2 s, and the readback matches the pattern.
- The sector erased in 0.2 s.
- Neighbouring sectors and the boot image are unchanged.

**Test generators** (5 s each, `--check`):

| run | records per port | drops per port | notes |
|---|---|---|---|
| `-p ab`, 60 B gap 10 | 43.4 M | 0 | FIFO peak 8 words |
| `-p ab`, 1514 B gap 180 | 2.1 M | 0 | FIFO peak 183 words |
| `-p b`, 60 B gap 3 (line rate) | 71.1 M | 0 | |
| `-p ab`, 60 B gap 3 | 49 884 615 and 49 884 614 | about 21.2 M | |

In the last run both generators run at line rate (2 x 14.2 Mframes/s), which is more than
PCIe x4 carries:
- The records per port differ by 1, because the merge alternates between the ports.
- The DMA carried 20.0 M records/s (1.6 GB/s of records).
- Every drop was reported inside the records, with 0 sequence errors. The FIFO peaked at 31 570
  of 32 768 words.

**Real traffic on both cages at once** (`-p ab --keep-fcs`, pcapng):
- Senders: oldgamer through the switch to SFP A, and zlab directly to SFP B.
- Each sent 800 pings (500 x 1042 B and 300 x 98 B frames) to an unknown MAC, set with static
  neighbour entries 02:4b:37:00:00:6f and 02:4b:37:00:01:6f.
- On each port all 800 frames are byte-identical to tcpdump on the sender, every FCS checks out,
  and nothing was dropped. SFP A also captured 163 other LAN frames.
- SFP A timestamps are 11-26 us after oldgamer's TX timestamps. SFP B shows the same spread of
  about 14 us. Its offset also includes zlab's clock offset to oldgamer, which was about 300 us
  in one run and under 25 us in the next.
- Reproduce with `test/pings_ab.sh TAG`.

**Line rate on SFP B:** zlab sent 1514 B frames at 9.84 Gb/s for 4 s with `echo10g`
(3.25 M frames).
- Without an output file: 3 250 984 frames, 0 drops, FIFO peak 191 words. FPGA RX_FRAMES, host
  records and zlab's `tx_packets_phy` all agree.
- With pcapng to the root disk (about 1.2 GB/s needed): the writer fell behind, the ring filled
  and the FPGA dropped whole frames. 2 013 064 captured + 1 237 832 dropped = 3 250 896 sent.
  606 906 of the drops were reported inside records; the rest came after the last record.
- Reproduce with `test/flood_b.sh` (or `-w` for the disk run). It needs zlab's `echo10g`.

**Drop-field cap:** both generators sent 1514 B frames at line rate for 8 s with pcapng to
disk. The ring stayed full, so 68 gaps between records exceeded 65535 drops (34 per port).
`--check` found 0 sequence errors, and host records == FPGA captured on each port.
