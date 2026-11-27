# fpga-rdma: software model of an FPGA RoCE v2 RDMA READ requester (no FPGA design yet)

A reference for a future FPGA RoCE engine. `fakefpga.py` does in Python, over raw Ethernet
frames, what the FPGA would do: it issues RDMA READs to a real RNIC and checks every response.
Its capture (`golden/`) is test data for the FPGA design.

Copied from zlab `~/fpga-rdma` on 2026-11-27, without the compiled `responder`. oldgamer had an
older copy of `fakefpga.py`; this is the newer one.

- `responder.cpp`, on zlab: exposes a 64 KB buffer for RDMA READ by a raw-frame requester. There
  is no CM; the QPs go to RTR only. It prints `key value` lines (addr, rkey, len, psn, qpn0/1,
  peer_qpn0/1), then `READY`. Usage: `responder DEV GIDIDX PEER_IPV4 [secs]`.
  Build: `g++ -O2 -o responder responder.cpp -libverbs`.
- `fakefpga.py`, on oldgamer as root: `fakefpga.py IFACE SRC_IP DST_IP DST_MAC PARAMS_FILE OUTDIR`.
  It builds the RoCE v2 frames itself (BTH, RETH, ICRC) and runs 16 cases:
  - reads of 1 B to 16 KB at unaligned offsets
  - a duplicate request
  - a request with a bad ICRC (must be dropped)
  - a PSN gap (NAK) and the resume after it
  - 4 outstanding 4 KB reads
  - a partial reissue
  - a bad rkey (NAK)
- `run.sh`, on zlab: starts the responder on mlx5_1, copies the parameters to oldgamer, runs
  fakefpga.py there on enp1s0f1np1 (25G port B), and copies `golden/` back. `params.txt` is
  the responder output of the last run.
- `oldgamer_roce.sh on|off`: switches RoCE on oldgamer's port B (devlink `enable_roce`; it reloads
  only that PCI function).
- `golden/` holds the last run's output:
  - `golden.pcap`: every frame, both directions
  - `golden.txt`: direction, test name and frame hex, one line per frame
  - `manifest.json`: parameters, addresses and per-test results
  - `mem/`: one `.mem` file per frame, one byte per line in wire order, no FCS, for `$readmemh`
    in an FPGA testbench; `INDEX.txt` lists them

**Last run (2026-11-25):** 15 of 16 cases passed. `partial_reissue` failed because the NIC
started the reissued response with a MIDDLE packet (0x0e) where the check expected FIRST.
`fakefpga.py` was then changed to accept that, but was not rerun, so `manifest.json` still
shows the old result.
