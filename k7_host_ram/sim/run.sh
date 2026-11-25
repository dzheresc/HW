#!/bin/bash
# Verilator testbench: modes 0 random mix + refused accesses, 1 reads flat out, 2 writes flat out, 3 mix + error/poisoned completions, 4 lost completion
H=$(cd "$(dirname "$0")" && pwd); O=${OBJ:-/tmp/hr_obj}; mkdir -p $O $O/t
verilator -Wall -Wno-fatal -Wno-UNUSEDSIGNAL -GTMO_BITS=12 -O3 --cc --exe --build -Mdir $O $H/../rtl/hr_core.v $H/tb.cpp > $O/build.log 2>&1 || { tail -20 $O/build.log; exit 1; }
grep -E '%Warn' $O/build.log; f=0
for s in $(seq ${SEEDS:-8}); do for m in 0 1 2 3 4; do timeout 100 $O/Vhr_core $s ${N:-20000} $m || { echo "seed $s mode $m rc=$?"; f=1; }; done; done
verilator -Wall -Wno-fatal -Wno-UNUSEDSIGNAL -O3 --cc --exe --build --top-module hr_test -Mdir $O/t $H/../rtl/hr_test.v $H/../rtl/hr_core.v $H/tb_test.cpp > $O/b2.log 2>&1 || { tail -20 $O/b2.log; exit 1; }
grep -E '%Warn' $O/b2.log; timeout 200 $O/t/Vhr_test || f=1; exit $f
