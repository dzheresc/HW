#!/bin/bash
# k7_cap rebuild with Vivado 2024.2: upgrade IP once, then full build. Pinned to NUMA node 1.
set -e
cd "$(dirname "$0")"
source /opt/Xilinx/Vivado/2024.2/settings64.sh
RUN="numactl --cpunodebind=1 --membind=1"
date; echo "== upgrade_ip"
$RUN vivado -mode batch -nojournal -log build_upgrade.log -source upgrade_ip.tcl > /dev/null
grep -E "IPS |ERROR" build_upgrade.log || true
date; echo "== build"
$RUN vivado -mode batch -nojournal -log build_2024.log -source build.tcl > /dev/null
date; echo "== done"; ls -la build/top.bit build/top.bin
