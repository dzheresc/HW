#!/bin/bash
# zlab responder (mlx5_1) <- software FPGA on oldgamer, port B
cd "$(dirname "$0")"; P="ssh -n -o BatchMode=yes 10.25.0.1"
sudo ./responder mlx5_1 3 10.26.0.1 60 > params.txt & R=$!
for i in $(seq 20); do grep -q READY params.txt && break; sleep .2; done; cat params.txt
$P mkdir -p fpga-rdma; scp -q fakefpga.py params.txt 10.25.0.1:fpga-rdma/
$P "cd fpga-rdma && sudo timeout 50 python3 fakefpga.py enp1s0f1np1 10.26.0.1 10.26.0.2 $(cat /sys/class/net/ens4f1np1/address) params.txt golden"
scp -qr 10.25.0.1:fpga-rdma/golden . ; sudo pkill -x responder; wait 2>/dev/null
