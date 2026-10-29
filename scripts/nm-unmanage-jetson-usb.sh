#!/bin/bash
# Keep NetworkManager off the Jetson's USB network link during an initrd flash.
# Otherwise NM retries DHCP on it, drops the flash tool's fc00:1:1::1 address and NFS fails mid-copy.
# Runs until killed; scripts/flash.sh starts and stops it.
while true; do
  for i in /sys/class/net/enx*; do
    [ -e "$i" ] || continue
    d=$(basename "$(readlink -f "$i/device/driver")")
    n=$(basename "$i")
    if [[ "$d" == rndis_host || "$d" == cdc_ncm || "$d" == cdc_ether ]] &&
       nmcli -t -f DEVICE,STATE device | grep -q "^$n:\(disconnected\|connecting\|unavailable\)"; then
      nmcli device set "$n" managed no && echo "$(date +%T) NetworkManager off for $n ($d)"
    fi
  done
  sleep 0.5
done
