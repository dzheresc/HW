# rdma-rtt: network benchmarks between zlab and oldgamer (host tools, no FPGA design)

Copied from zlab `~/rdma-rtt` on 2026-11-27. The sources, scripts and result tables are here.
Compiled binaries, the backup `flood.cpp.orig` and the run logs were left out. All scripts run
on zlab and reach oldgamer over ssh.

Links:
- 25G port A: zlab ens4f0np0 10.25.0.2 to oldgamer enp1s0f0np0 10.25.0.1.
- 25G port B with RoCE v2: zlab ens4f1np1 10.26.0.2 to oldgamer enp1s0f1np1 10.26.0.1.
- 10G: zlab ens6 to the K7 card's SFP B.

| file | what it does |
|---|---|
| `rttbench.cpp` | Ping-pong RTT over TCP, UDP and RDMA RC (send, write, read). `rttbench server CONTROL_IP`; `rttbench client CONTROL_IP [--iters N] [--rounds N] [--awake] [--csv F]`. Only the client takes timestamps, so no clock sync is needed. `--awake` holds `/dev/cpu_dma_latency` at 0. |
| `run.sh` | Builds rttbench, starts the server on oldgamer and runs the client: `./run.sh stock` or `./run.sh awake`. Writes `results-MODE.txt` and `.csv`. |
| `results-stock.*`, `results-awake.*` | rttbench results, 2026-11-25: 16 B to 8192 B, 9 rounds of 10000, ports A and B. For example, a 16 B RDMA send with polling on port B has a p50 of 1.74 us (stock). |
| `flood.cpp` | Overloads a receiver with UDP, RC SEND or UD SEND and accounts for every message (sequence number and tag). `flood rx CTRL_IP DATA_IP IFACE`; `flood tx CTRL_IP DATA_DST DATA_SRC MODE SIZE SECS FLOWS RCVBUF DELAY_NS`. Env options: `FLOOD_GRO=1`, `FLOOD_PIN=cpu,list`. |
| `flood.sh` | Floods port B in both directions. |
| `tune.sh`, `rxcase.sh` | UDP receive-tuning ablation. `rxcase.sh` runs on the receiver as root: it applies one set of settings (ring size, ntuple steering, CPU pinning, governor, GRO, no conntrack), runs the receiver, and always restores the settings. |
| `ab.sh` | UDP on port A against RDMA RC on port B. |
| `echo10g.cpp` | Floods the k7_link UDP echo (port 7) on the FPGA and counts what comes back: `echo10g DST SIZE SECS FLOWS GRO`. k7_cap_ab's `test/flood_b.sh` also uses it as a 10G line-rate source. |

Build (the scripts build what they need):

    g++ -O2 -std=c++17 -Wall -o rttbench rttbench.cpp -libverbs
    g++ -O2 -std=c++17 -Wall -Wno-misleading-indentation -o flood flood.cpp -libverbs -pthread
    g++ -O2 -std=c++17 -Wall -o echo10g echo10g.cpp -pthread
