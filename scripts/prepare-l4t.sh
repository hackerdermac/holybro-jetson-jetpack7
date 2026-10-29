#!/bin/bash
# Extract the L4T R39.2.1 BSP and apply the Holybro port: patched DTBs + board-conf overlay line.
# Usage: scripts/prepare-l4t.sh [WORK]   (WORK defaults to ~/jetson-jp7)
# Needs: WORK/dl/Jetson_Linux_R39.2.1_aarch64.tbz2. NVIDIA's originals are kept as *.stock.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-$HOME/jetson-jp7}
L4T=$WORK/Linux_for_Tegra

(cd "$REPO/dtb" && sha256sum -c --quiet SHA256SUMS)

if [ ! -f "$L4T/flash.sh" ]; then
  echo "extracting BSP..."
  tar -C "$WORK" -xjf "$WORK/dl/Jetson_Linux_R39.2.1_aarch64.tbz2"
fi
ver=$(. "$L4T/nv_tegra/bsp_version" && echo "$BSP_VERSION")
[ "$ver" = "39.2.1" ] || { echo "$L4T is L4T $ver, not R39.2.1"; exit 1; }

for f in "$REPO"/dtb/*.dtb; do
  dst=$L4T/kernel/dtb/$(basename "$f")
  [ -f "$dst.stock" ] || cp "$dst" "$dst.stock"
  cp "$f" "$dst"
done
echo "installed $(ls "$REPO"/dtb/*.dtb | wc -l) Holybro DTBs"

CONF=$L4T/p3768-0000-p3767-0000-a0.conf
LINE='OVERLAY_DTB_FILE+=",tegra234-p3767-camera-p3768-imx219-dual.dtbo";'
if ! grep -qF "$LINE" "$CONF"; then
  [ -f "$CONF.stock" ] || cp "$CONF" "$CONF.stock"
  sed -i "/^OVERLAY_DTB_FILE+=\",tegra234-p3768-0000+p3767-0000-dynamic.dtbo\";/a $LINE" "$CONF"
fi
grep -qF "$LINE" "$CONF" && echo "board conf: IMX219 dual overlay enabled"
