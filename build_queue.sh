#!/bin/bash
# Rebuild all Vivado projects with 2024.2, two jobs per NUMA node. Nothing is flashed or loaded.
cd "$(dirname "$0")"
run() { ./timed_build.sh "$@" > "$1/timed.out" 2>&1 && echo "OK   $1: $(tail -2 $1/timed.out | tr '\n' ' ')" || echo "FAIL $1: $(tail -3 $1/timed.out | tr '\n' ' ')"; }
export -f run
node0="k7_cap:upgrade_ip:build k7_10g_os:upgrade_ip:build k7_10g:upgrade_ip:build k7_nic:upgrade_ip:build k7_pcie:upgrade_ip:build ku5p_pcie:gen_ip:build blink:../proj_build eth_recv:../proj_build udp:../proj_build"
node1="ku5p_ddr:gen_ip:build k7_udp:upgrade_ip:build k7_link:upgrade_ip:build ku5pf_ddr:gen_ip:build udp_2:../proj_build arty_blink:scripts/build blink.up:build"
q() { local n=$1; shift; for j in "$@"; do IFS=: read -r d s <<< "$j"; echo "run $d 2024.2 $n ${s//:/ }"; done | xargs -P2 -I{} bash -c '{}'; }
q 0 $node0 > queue_node0.out 2>&1 &
q 1 $node1 > queue_node1.out 2>&1 &
wait; echo "ALL DONE"; cat queue_node0.out queue_node1.out
