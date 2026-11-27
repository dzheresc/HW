#!/bin/bash
# Flood port B in both directions. Run on zlab. Usage: ./flood.sh [secs]
cd "$(dirname "$0")"; S=${1:-8}; P="ssh -o BatchMode=yes 10.25.0.1"; D=rdma-rtt
g++ -O2 -std=c++17 -Wall -Wno-misleading-indentation -o flood flood.cpp -libverbs -pthread || exit 1
scp -q flood 10.25.0.1:$D/
matrix(){ # cmd-prefix ctrl dst src
 for sz in 18 512 8192; do
  $1 tx $2 $3 $4 udp $sz $S 4 0 0
  $1 tx $2 $3 $4 udp $sz $S 4 67108864 0
  $1 tx $2 $3 $4 rc $sz $S 4 0 0
  [ $sz -le 4096 ] && $1 tx $2 $3 $4 ud $sz $S 4 0 0
 done
 echo "-- slow consumer: 5 us of work per message"
 $1 tx $2 $3 $4 udp 512 $S 4 67108864 5000
 $1 tx $2 $3 $4 rc 512 $S 4 0 5000
 $1 tx $2 $3 $4 ud 512 $S 4 0 5000
 $1 tx $2 $3 $4 QUIT >/dev/null 2>&1
}
echo "===== oldgamer -> zlab (zlab receives)"
sudo timeout 900 ./flood rx 10.25.0.2 10.26.0.2 ens4f1np1 & sleep 1.5
matrix "$P sudo $D/flood" 10.25.0.2 10.26.0.2 10.26.0.1
sudo pkill -x flood; wait
echo "===== zlab -> oldgamer (oldgamer receives)"
$P "sudo timeout 900 $D/flood rx 10.25.0.1 10.26.0.1 enp1s0f1np1" & sleep 2
matrix "sudo ./flood" 10.25.0.1 10.26.0.1 10.26.0.2
$P 'sudo pkill -x flood'; wait
