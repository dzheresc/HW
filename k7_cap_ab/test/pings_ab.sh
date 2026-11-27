#!/bin/bash
# Real-traffic test of k7_cap_ab on both cages at once (README, "Verified on hardware").
# Starts `k7cap -p ab --keep-fcs` (pcapng) on the capture host, then sends pings to an unknown
# MAC on each cage, from the capture host through the LAN switch (it floods unknown unicast to
# SFP A) and from the peer wired straight to SFP B. tcpdump on each sender is the reference,
# and cmp_pcapng.py compares the frames byte for byte and checks every FCS.
#
# Usage: test/pings_ab.sh TAG [NPINGS]       local copies in ${TMPDIR:-/tmp}/k7ab_runs/TAG (or $OUT/TAG)
# Needs: ssh aliases with passwordless sudo on both hosts, k7cap built in ~/k7_cap_ab on the
# capture host, the k7_cap_ab bitstream loaded. Override the defaults below with env variables.
set -u
TAG=${1:?usage: pings_ab.sh TAG [NPINGS]}; N=${2:-500}
CAP=${CAP:-oldgamer}  CAP_IF=${CAP_IF:-enp3s0}  A_IP=${A_IP:-192.168.0.111}  A_MAC=${A_MAC:-02:4b:37:00:00:6f}
PEER=${PEER:-zlab}    PEER_IF=${PEER_IF:-ens6}  B_IP=${B_IP:-10.10.0.111}    B_MAC=${B_MAC:-02:4b:37:00:01:6f}
CORE=${CORE:-3}
R=k7ab_runs                                   # work directory on both hosts, under the login dir
HERE=$(cd "$(dirname "$0")" && pwd); OUT=${OUT:-${TMPDIR:-/tmp}/k7ab_runs}/$TAG
TD=$(( (N + 300) / 100 + 8 ))                 # tcpdump seconds: both ping runs plus margin
CT=$(( TD + 10 ))                             # capture seconds
S="ssh -o BatchMode=yes"
ts() { date +%T.%N | cut -c1-12; }

# k7cap must be a background command of its own: in "cd dir && nohup ... &" the whole && list
# runs in a subshell that keeps the ssh session open, so ssh would return only after k7cap ends.
$S $CAP "mkdir -p $R; rm -f $R/$TAG*; sudo -n ip neigh replace $A_IP lladdr $A_MAC dev $CAP_IF nud permanent; cd ~/k7_cap_ab || exit 1; nohup sudo -n timeout $((CT + 30)) ./k7cap -p ab -w ~/$R/$TAG.pcapng --keep-fcs -t $CT -q -c $CORE > ~/$R/$TAG.log 2>&1 < /dev/null &" || exit 1
echo "$(ts) k7cap started for $CT s"
$S $PEER "mkdir -p $R; rm -f $R/$TAG*; sudo -n ip neigh replace $B_IP lladdr $B_MAC dev $PEER_IF nud permanent" || exit 1
sleep 3

send() {  # host iface ip mac reference-file
  $S $1 "nohup sudo -n timeout $TD tcpdump -i $2 -nn -s0 -w ~/$R/$5 --time-stamp-precision=nano 'ether dst $4' > /dev/null 2>&1 < /dev/null & sleep 1; ping -c $N -i 0.01 -W 1 -s 1000 -q $3 | grep -o '^[0-9]* packets transmitted'; ping -c 300 -i 0.01 -W 1 -s 56 -q $3 | grep -o '^[0-9]* packets transmitted'" | sed "s/^/$1: /"
}
echo "$(ts) pings start"
send $CAP $CAP_IF $A_IP $A_MAC ${TAG}_a.pcap &
send $PEER $PEER_IF $B_IP $B_MAC ${TAG}_b.pcap &
wait
echo "$(ts) pings done"
$S $CAP "while pgrep -x k7cap > /dev/null; do sleep 0.5; done; sudo -n ip neigh del $A_IP dev $CAP_IF; sudo -n chown \$(id -un): $R/$TAG*; grep -E '^(host|fpga|OK|MISM)' $R/$TAG.log"
$S $PEER "while pgrep -x tcpdump > /dev/null; do sleep 0.5; done; sudo -n ip neigh del $B_IP dev $PEER_IF; sudo -n chown \$(id -un): $R/$TAG*"
mkdir -p "$OUT"
scp -q $CAP:$R/$TAG.pcapng $CAP:$R/${TAG}_a.pcap "$OUT/" && scp -q $PEER:$R/${TAG}_b.pcap "$OUT/" &&
  python3 -I "$HERE/cmp_pcapng.py" "$OUT/$TAG.pcapng" 0 $A_MAC "$OUT/${TAG}_a.pcap" 1 $B_MAC "$OUT/${TAG}_b.pcap"
