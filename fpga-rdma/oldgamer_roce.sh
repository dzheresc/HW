#!/bin/bash
# on|off : RoCE on oldgamer port B (reloads that PCI function only)
D=pci/0000:01:00.1; V=false; [ "$1" = on ] && V=true
devlink dev param set $D name enable_roce value $V cmode driverinit && devlink dev reload $D
for i in $(seq 40); do ip -br a show enp1s0f1np1 2>/dev/null | grep -q 'UP.*10.26.0.1' && break; sleep .5; done
ip -br a show enp1s0f1np1; ls /sys/class/infiniband; devlink dev param show $D name enable_roce | tail -1; cat /sys/class/net/enp1s0f1np1/mtu
