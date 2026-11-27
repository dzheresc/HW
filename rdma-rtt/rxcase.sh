#!/bin/bash
# Runs ON THE RECEIVER as root: apply settings, run the flood receiver, always restore.
# rxcase.sh IFACE CTRL_IP DATA_IP RING(0/1) STEER("" or queue list) PIN("" or cpu list) PERF(0/1) GRO(0/1) NOTRACK(0/1)
cd "$(dirname "$0")"; I=$1; RING=$4; STEER=$5; PIN=$6; PERF=$7; GRO=$8; NT=$9
OR=$(ethtool -g $I | awk '/Current/{f=1} f&&/^RX:/{print $2;exit}'); OG=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
ON=$(ethtool -k $I | awk '/ntuple/{print $2}')
gov(){ for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo $1 > $g; done; }
restore(){ trap - EXIT; [ -n "$FP" ] && kill $FP 2>/dev/null
 [ -n "$STEER" ] && { for l in 0 1 2 3; do ethtool -N $I delete $l; done; ethtool -K $I ntuple $ON; } 2>/dev/null
 [ $RING = 1 ] && ethtool -G $I rx $OR; [ $PERF = 1 ] && gov $OG; [ $NT = 1 ] && nft delete table ip floodnt; }
trap restore EXIT; trap 'exit 1' INT TERM HUP
[ $RING = 1 ] && { ethtool -G $I rx 8192 || echo SETFAIL ring; }
if [ -n "$STEER" ]; then ethtool -K $I ntuple on; n=0; for q in ${STEER//,/ }; do ethtool -N $I flow-type udp4 dst-port $((18800+n)) action $q loc $n || echo SETFAIL steer; n=$((n+1)); done; fi
[ $PERF = 1 ] && gov performance
[ $NT = 1 ] && { nft "add table ip floodnt; add chain ip floodnt p { type filter hook prerouting priority -300; }; add rule ip floodnt p iifname $I udp dport 18800-18803 notrack" || echo SETFAIL nt; }
FLOOD_GRO=$GRO FLOOD_PIN=$PIN timeout 120 ./flood rx $2 $3 $I & FP=$!
wait $FP; FP=
