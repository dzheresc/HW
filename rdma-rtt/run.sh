#!/bin/bash
# Usage: ./run.sh [stock|awake] [extra client options]   (run on zlab)
set -e
cd "$(dirname "$0")"
MODE=${1:-stock}; shift || true
PEER=10.25.0.1; FLAG=""; [ "$MODE" = awake ] && FLAG=--awake
g++ -O2 -std=c++17 -Wall -o rttbench rttbench.cpp -libverbs
ssh -o BatchMode=yes $PEER 'mkdir -p ~/rdma-rtt'
scp -q -o BatchMode=yes rttbench $PEER:rdma-rtt/
ssh -o BatchMode=yes $PEER "sudo timeout 1500 ~/rdma-rtt/rttbench server $PEER $FLAG" > server-$MODE.log 2>&1 &
sleep 2
sudo timeout 1500 ./rttbench client $PEER $FLAG --csv results-$MODE.csv "$@" | tee results-$MODE.txt
wait
