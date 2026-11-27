#!/bin/bash
# UDP on port A vs RDMA RC on port B; control and ssh over port B. Run on zlab. ab.sh OIFACE_A SECS ROUNDS
cd "$(dirname "$0")"; OA=$1; S=$2; R=$3; P="ssh -n -o BatchMode=yes -o HostKeyAlias=10.25.0.1 10.26.0.1"; B=67108864
scp -q -o HostKeyAlias=10.25.0.1 flood rxcase.sh 10.26.0.1:rdma-rtt/ || exit 1
one(){ # dir mode name ring steer pin perf gro nt
 local d=$1 mode=$2 nm=$3; shift 3
 if [ $d = Z ]; then
  if [ $mode = udp ]; then I=ens4f0np0; DA="10.25.0.2 10.25.0.1"; L=10.25.0.2; else I=ens4f1np1; DA="10.26.0.2 10.26.0.1"; L=10.26.0.2; fi
  sudo ./rxcase.sh $I 10.26.0.2 $L "$@" & TX="$P sudo rdma-rtt/flood"; C=10.26.0.2
 else
  if [ $mode = udp ]; then I=$OA; DA="10.25.0.1 10.25.0.2"; L=10.25.0.1; else I=enp1s0f1np1; DA="10.26.0.1 10.26.0.2"; L=10.26.0.1; fi
  $P "sudo rdma-rtt/rxcase.sh $I 10.26.0.1 $L $1 '$2' '$3' $4 $5 $6" & TX="sudo ./flood"; C=10.26.0.1
 fi
 sleep 5
 for n in 18 512 1472 8192; do b=$B; [ $mode = rc ] && b=0; echo "r$r $d $nm | $($TX tx $C $DA $mode $n $S 4 $b 0 2>&1)"; done
 $TX tx $C $DA QUIT a a a a a >/dev/null 2>&1; wait
}
for r in $(seq $R); do
 one Z udp A-udp-base    0 "" "" 0 0 0
 one Z udp A-udp-gro     0 "" "" 0 1 0
 one Z udp A-udp-all     1 "0,1,2,3" "6,7,8,9" 1 1 1
 one Z rc  B-rdma-rc     0 "" "" 0 0 0
 one O udp A-udp-base    0 "" "" 0 0 0
 one O udp A-udp-gro     0 "" "" 0 1 0
 one O udp A-udp-split   1 "0,1,0,1" "2,3,2,3" 1 1 0
 one O rc  B-rdma-rc     0 "" "" 0 0 0
done
