#!/bin/bash
# Usage: timed_build.sh <project dir> <vivado ver> <numa node> [gen_ip]
# Runs [gen_ip.tcl] + build.tcl in batch mode, pinned to one NUMA node, and logs wall time per step.
set -e
cd "$(dirname "$0")/$1"; ver=$2; node=$3
source /opt/Xilinx/Vivado/$ver/settings64.sh
RUN="numactl --cpunodebind=$node --membind=$node"
step() { local t0=$(date +%s); echo "$(date -u +%T) start $1"; $RUN vivado -mode batch -nojournal -log build_$(basename $1).log -source $1.tcl > build_$(basename $1).out 2>&1 || { echo "$1 FAILED"; exit 1; }; echo "$(date -u +%T) end $1: $(( ($(date +%s)-t0)/60 )) min $(( ($(date +%s)-t0)%60 )) s"; }
T0=$(date +%s)
for s in "${@:4}"; do step $s; done
echo "TOTAL $(( ($(date +%s)-T0)/60 )) min"; grep -h "BUILD DONE" build_build.log || true
