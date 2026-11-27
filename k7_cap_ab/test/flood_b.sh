#!/bin/bash
# Line-rate test of k7_cap_ab on SFP B (README, "Verified on hardware"). The peer, wired straight
# to SFP B, floods an unknown MAC with 1514-byte frames while `k7cap -p b` runs on the capture
# host; FPGA RX_FRAMES and the host's records must equal the peer NIC's PHY transmit counter.
#
# Usage: test/flood_b.sh [-w]     -w: also write pcapng to disk on the capture host (then deleted)
# Needs: echo10g on the peer (~/rdma-rtt, not in this repo; it sends 1514 B frames at 9.84 Gb/s
# for 4 s), or FLOOD="command" that floods $B_IP from the peer; `ethtool -S` with a
# tx_packets_phy counter (mlx4). Other defaults as in pings_ab.sh.
set -u
CAP=${CAP:-oldgamer}  PEER=${PEER:-zlab}  PEER_IF=${PEER_IF:-ens6}  CORE=${CORE:-3}
B_IP=${B_IP:-10.10.0.111}  B_MAC=${B_MAC:-02:4b:37:00:01:6f}
FLOOD=${FLOOD:-"cd ~/rdma-rtt && sudo -n timeout 20 ./echo10g $B_IP 1472 4 4 0 > /dev/null 2>&1"}
R=k7ab_runs; W=""; [ "${1:-}" = "-w" ] && W="-w ~/$R/flood.pcapng"
S="ssh -o BatchMode=yes"

# k7cap as a background command of its own (see pings_ab.sh)
$S $CAP "mkdir -p $R; cd ~/k7_cap_ab || exit 1; nohup sudo -n timeout 60 ./k7cap -p b -t 16 -c $CORE $W > ~/$R/flood.log 2>&1 < /dev/null &" || exit 1
sleep 3
$S $PEER "sudo -n ip neigh replace $B_IP lladdr $B_MAC dev $PEER_IF nud permanent; T0=\$(ethtool -S $PEER_IF | awk '/tx_packets_phy/{print \$2}'); $FLOOD; T1=\$(ethtool -S $PEER_IF | awk '/tx_packets_phy/{print \$2}'); echo \"$PEER $PEER_IF tx_packets_phy +\$((T1 - T0))\"; sudo -n ip neigh del $B_IP dev $PEER_IF"
$S $CAP "while pgrep -x k7cap > /dev/null; do sleep 0.5; done; awk '/ B .*pkt\\/s/ && \$3 > 0' $R/flood.log; grep -E '^(host B|host:|fpga B|OK B|MISM)' $R/flood.log; rm -f $R/flood.pcapng"
