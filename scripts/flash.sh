#!/bin/bash
# Flash JetPack 7.2.1 with the Holybro port to the Jetson's NVMe, from an Ubuntu 22.04 container.
# Usage: scripts/flash.sh   (run scripts/prepare-l4t.sh first)
# Asks for: sudo on this PC, the Jetson username/password, NVIDIA's license, then recovery mode.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
LOG=$REPO/flash.log
[ -f "$REPO/Linux_for_Tegra/flash.sh" ] || { echo "run scripts/prepare-l4t.sh first"; exit 1; }

"$REPO/scripts/nm-unmanage-jetson-usb.sh" &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null; sudo sed -i "s/\(Password - \)[^,]*/\1***/" "$LOG" 2>/dev/null || true' EXIT

sudo script -qfec "docker run --rm -it --privileged --net=host \
  -v /dev:/dev -v /lib/modules:/lib/modules:ro \
  -v $REPO:/repo \
  ubuntu:22.04 bash /repo/scripts/flash-in-container.sh" "$LOG"
