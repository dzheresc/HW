# k7_cap: 10G packet capture to host memory over PCIe Gen2 x4 (xc7k325t board)

Based on `k7_nic` (BAR0 flash programmer, license-free 10GBASE-R on both SFP+ cages).
The PCIe endpoint is widened to **Gen2 x4** (pcie_7x, 64-bit AXI-ST at 250 MHz, 10ee:7022),
and every frame received on **SFP A** (the DAC to the switch) is timestamped, buffered on
chip and written by DMA into a ring of hugepages in host memory. SFP A transmits XGMII idle
only; nothing is ever sent on the wire. No MAC filtering (promiscuous); frames with FCS or
framing errors and the FCS bytes themselves can optionally be kept.

## Data path

```
SFP A RX PCS (156.25 MHz recovered)            PCIe user clock (250 MHz)
  axis_xgmii_rx_64 ──┐                          ┌─> serializer ─> prefetch FIFO ─> MWr TLP writer ──> TX arbiter ─> pcie_7x
  (patched: keep FCS)├─> ingress ─> data FIFO ──┤   (16 B record header + data)   (MPS-sized, 3DW/4DW)   (with MMIO completions)
  cap_testgen ───────┘   (drop     256 KB       │
                          whole     meta FIFO ──┘   head writeback (8 B MWr) <── host polls it
                          frames)   4096 entries     tail doorbell (MMIO)    ──> host writes it
```

- `rtl/cap_top.v`     capture block: registers 0x100..0x1FF, clock crossings, timestamp counter
- `rtl/cap_ingress.v` per-frame admission (room for snaplen in the data FIFO and a descriptor),
                      drop counting, record descriptors
- `rtl/cap_dma.v`     serializer, block table (1024 entries), ring writer, status writeback
- `rtl/cap_testgen.v` internal frame generator (replaces the MAC input, never the wire)
- `rtl/afifo.v`       dual-clock FIFO (block RAM, Gray pointers, FWFT, 1 word/clock)
- `rtl/verilog-ethernet/axis_xgmii_rx_64.v` local patch: `cfg_keep_fcs` passes the 4 FCS bytes
- `rtl/top.v`         pcie_x4 + PIO + JTAG-to-AXI + STARTUPE2 flash + eth10g + cap_top + TX arbiter
- `sim/run_sim.sh`    xsim testbench (see below); `gen_ip.tcl` generates `ip/pcie_x4`
- `host/k7cap.cpp`    capture tool; `host/k7flash.cpp` as in k7_nic (also finds 10ee:7022)

**Drops are honest.** A frame is admitted only if the data FIFO has room for a full snaplen
and the meta FIFO has a free entry; otherwise it is dropped whole and counted. The writer
never overruns the host: it stops when `head - tail` reaches the ring size, so a slow host
fills the on-chip FIFO and shows up as ingress drops. Each record carries the number of frames
dropped right before it, so the host can place every gap; the host total equals `DROP_FRAMES`
except for drops after the last record.

**Timestamps** come from a free-running 64-bit counter on the 156.25 MHz TX PCS clock (local
SFP refclk, 6.4 ns ticks), taken at the first word of the frame out of the MAC.
`k7cap` anchors it to `CLOCK_REALTIME` once at start.

## Ring and record format

The ring is `nblocks` blocks of `2^blk_shift` bytes (k7cap: 2 MB hugepages, block i at the
bus address in table entry i). `head` (bytes written since reset) is written to the status
address every `STAT_THR` bytes and after `TIMEOUT` of quiet; posted writes are ordered, so
every byte below a reported head is in memory. The host returns space with `TAIL` (low 32 bits
of its consumed byte count). Records are 8-byte aligned, little endian:

| bytes | field |
|---|---|
| 0..7   | timestamp, 6.4 ns ticks |
| 8..9   | captured length (bytes stored, <= snaplen) |
| 10..11 | wire length (bytes from the MAC; includes the FCS if kept) |
| 12     | flags: [0] FCS/framing error [1] truncated [2] FCS included [3] aborted (link reset mid-frame) |
| 13     | 0 |
| 14..15 | frames dropped just before this record (saturates at 65535) |
| 16..   | frame data, padded to a multiple of 8 |

## Registers (BAR0, 4 KB; also over JTAG-to-AXI)

0x000..0xBFF as k7_nic (ID 0x4B375043, **VERSION 0x00040000**; SPI SCK half period now in
250 MHz cycles, reset 8 = 15.6 MHz as before). Capture block:

| off | name | |
|---|---|---|
| 0x100 | CTRL | RW [0] enable [1] reset (held while 1) [2] keep bad frames [3] keep FCS [4] test generator |
| 0x104 | STATUS | RO [0] bus master enable [1] DMA running [4:2] Device Control MPS [5] SFP A block lock [25:16] prefetch level |
| 0x108 | SNAPLEN | RW bytes per frame, multiple of 8, 64..16384 (reset 9600) |
| 0x10C | BLKCFG | RW [4:0] log2 block size 12..30 (reset 21) [26:16] blocks 1..1024 (ring <= 1 GB) |
| 0x110 | TBL_IDX | RW table index (auto-increment on TBL_HI) |
| 0x114/0x118 | TBL_LO/HI | block bus address; writing HI stores the entry |
| 0x11C | TIMEOUT | RW flush / status timeout, 4 ns units (reset 250 = 1 us) |
| 0x120/0x124 | STAT_LO/HI | status writeback bus address |
| 0x128 | STAT_THR | RW bytes between status writes (reset 65536) |
| 0x12C | TAIL | RW host consumed bytes, low 32 bits |
| 0x130 | HEAD | RO 64-bit (read lo first, it latches hi) |
| 0x138 | TS | RO 64-bit timestamp now |
| 0x140 | TG_CFG | RW test generator [15:0] frame bytes [31:16] idle cycles after each |
| 0x144 | FIFO_MAX | RO highest data FIFO level since reset (words of 8 bytes, 32768 total) |
| 0x150.. | counters | RO 64-bit: RX_FRAMES, RX_BYTES, CAP_FRAMES, DROP_FRAMES, BAD_FRAMES, RECORDS, TLPS, STALLS, TG_SEQ (0x150 + 8 n) |

Change SNAPLEN, TG_CFG and the CTRL keep bits while enable is 0. After enable drops, the DMA
keeps draining what is buffered until the next reset.

## Host tool

Needs root (sysfs BAR mmap, config space, `/proc/self/pagemap`) and no IOMMU (oldgamer's
i5-3570K has no VT-d, so bus addresses are physical). It reserves hugepages itself if needed.

    g++ -O2 -std=c++17 -pthread -o k7cap k7cap.cpp
    sudo ./k7cap -w cap.pcap -c 3            # capture SFP A until Ctrl-C, RX thread on core 3
    sudo ./k7cap -t 10 --testgen 60,3 --check   # internal line-rate generator, verify sequence

Options: `-s SNAPLEN`, `-m RING_MB`, `-n COUNT`, `-t SECONDS`, `--keep-bad`, `--keep-fcs`, `-q`.
The pcap uses nanosecond timestamps (magic a1b23c4d), linktype Ethernet. The receive thread
copies records into 4 MB buffers handed to a writer thread; if the writer (disk) falls
behind, the ring fills and the FPGA drops, which the statistics show.

## Simulation

`sim/run_sim.sh` (xsim): XGMII frames with real CRCs (lane 0 and lane 4 starts, 10% bad FCS),
TLPs into a memory model with random backpressure, a host-style consumer that checks every
record byte for byte against the sent frames, skipping exactly the reported drops. Phase 1
FCS stripped / bad discarded, phase 2 FCS + bad kept, snaplen 128, slow host (ring full,
1191 drops, all accounted), phase 3 generator at line rate (60 B): no drops. Prints PASS.

## Build and load (Vivado 2017.4; volatile, flash untouched)

    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source gen_ip.tcl     # once
    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source build.tcl
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove'
    C:\Xilinx\Vivado\2017.4\bin\vivado.bat -mode batch -source program.tcl -tclargs 192.168.0.215:3121
    ssh shed 'echo 1 | sudo tee /sys/bus/pci/rescan'
    ssh shed 'cd k7_cap && sudo ./k7flash status && sudo ./k7cap -t 5 --testgen 60,3 --check'

## Verified on hardware (2026-11-19, JTAG load, oldgamer)

Build: 44 min on the Dell, timing met (WNS +0.297 ns), 11.5k LUTs, 87.5 BRAM tiles.
02:00.0 10ee:7022 LnkSta 5GT/s **x4**, root port MPS 128; flash/10G status as in k7_nic.

- Test generator, 5 s each, `--check`: 60 B gap 3 (14.2 Mpps), 60 B gap 1 (17.4 Mpps, above line
  rate, about 1.3 GB/s of DMA), 64 B gap 2, 1514 B gap 1: 0 drops, 0 sequence errors, host records
  == FPGA captured (up to 87 M records per run), on-chip FIFO peak at most 192 of 32768 words.
- Drop honesty: pcap to the root disk (~0.8 GB/s) with 1514 B at line rate and a 16 MB ring:
  1 175 193 frames dropped by the FPGA, 1 172 728 reported inside records (the rest after the
  last record), every sequence gap equal to the reported drops, 0 sequence errors.
- Real traffic: oldgamer pings an unknown MAC (static neighbour entry 02:4b:37:00:00:6f, so the
  switch floods it to SFP1): 500/500 ICMP frames in the k7cap pcap are byte-identical to tcpdump
  on enp3s0; FPGA timestamps are 27-31 us after oldgamer's TX timestamps (1G serialization +
  switch), steady after the per-second clock-rate correction. With `--keep-fcs` all frames are
  4 bytes longer and every FCS checks out (zlib.crc32).
- pcap writing to /dev/shm keeps up at 1.2 GB/s.

`RX_FRAMES` counts every frame the MAC delivered since the last reset, including the few that
arrive between reset and enable (or after disable); those are neither captured nor drops.
