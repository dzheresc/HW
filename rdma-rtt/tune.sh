#!/bin/bash
# UDP receive tuning ablation, run on zlab. tune.sh [secs] [rounds]
cd "$(dirname "$0")"; S=${1:-5}; R=${2:-3}; P="ssh -o BatchMode=yes 10.25.0.1"; B=67108864
g++ -O2 -std=c++17 -Wall -Wno-misleading-indentation -o flood flood.cpp -libverbs -pthread || exit 1
chmod +x rxcase.sh; scp -q flood rxcase.sh 10.25.0.1:rdma-rtt/ || exit 1
one(){ # dir name ring steer pin perf gro nt
 local d=$1 nm=$2; shift 2
 if [ $d = Z ]; then sudo ./rxcase.sh ens4f1np1 10.25.0.2 10.26.0.2 "$@" & TX="$P sudo rdma-rtt/flood"; A="10.25.0.2 10.26.0.2 10.26.0.1"
 else $P "sudo rdma-rtt/rxcase.sh enp1s0f1np1 10.25.0.1 10.26.0.1 $1 '$2' '$3' $4 $5 $6" & TX="sudo ./flood"; A="10.25.0.1 10.26.0.1 10.26.0.2"; fi
 sleep 4
 for c in "18 0" "512 0" "8192 0" "512 5000"; do set -- $c; echo "r$r $d $nm | $($TX tx $A udp $1 $S 4 $B $2 2>&1)"; done
 $TX tx $A QUIT a a a a a >/dev/null 2>&1; wait
}
for r in $(seq $R); do
 one Z base          0 ""        ""        0 0 0
 one Z ring          1 ""        ""        0 0 0
 one Z ring+steer    1 "0,1,2,3" ""        0 0 0
 one Z +pin          1 "0,1,2,3" "6,7,8,9" 0 0 0
 one Z +perf         1 "0,1,2,3" "6,7,8,9" 1 0 0
 one Z +notrack      1 "0,1,2,3" "6,7,8,9" 1 0 1
 one Z +gro          1 "0,1,2,3" "6,7,8,9" 1 1 1
 one Z gro-only      0 ""        ""        0 1 0
 one O base          0 ""        ""        0 0 0
 one O ring          1 ""        ""        0 0 0
 one O ring+steer    1 "0,1,2,3" ""        0 0 0
 one O +pin-same     1 "0,1,2,3" "0,1,2,3" 0 0 0
 one O split2+2      1 "0,1,0,1" "2,3,2,3" 0 0 0
 one O steer+perf+gro   1 "0,1,2,3" ""     1 1 0
 one O split+perf+gro   1 "0,1,0,1" "2,3,2,3" 1 1 0
 one O gro-only      0 ""        ""        0 1 0
done
