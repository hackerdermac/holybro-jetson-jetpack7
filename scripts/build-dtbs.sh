#!/bin/bash
# Rebuild the Holybro-patched Orin NX/Nano DTBs (dtb/) from the L4T R39.2.1 public sources.
# Usage: scripts/build-dtbs.sh
# Needs: public_sources.tbz2 in the repo folder, Linux_for_Tegra/ (BSP, for its dtc), host cpp and patch.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
L4T=$REPO/Linux_for_Tegra
SRC=$REPO/src
[ -f "$REPO/public_sources.tbz2" ] || { echo "put public_sources.tbz2 into $REPO"; exit 1; }
DTC=$L4T/kernel/dtc
[ -x "$DTC" ] || { echo "BSP not extracted: $DTC missing (run scripts/prepare-l4t.sh first)"; exit 1; }

if [ ! -d "$SRC/stock/hardware" ]; then
  echo "extracting device-tree and kernel-include sources..."
  mkdir -p "$SRC/stock" "$SRC/kernel"
  tar xjf "$REPO/public_sources.tbz2" -C "$SRC" \
    Linux_for_Tegra/source/kernel_oot_modules_src.tbz2 Linux_for_Tegra/source/kernel_src.tbz2
  tar xjf "$SRC/Linux_for_Tegra/source/kernel_oot_modules_src.tbz2" -C "$SRC/stock" hardware
  tar xjf "$SRC/Linux_for_Tegra/source/kernel_src.tbz2" -C "$SRC/kernel" --wildcards \
    'kernel/kernel-noble/include/*' 'kernel/kernel-noble/scripts/dtc/include-prefixes/*'
fi
if [ ! -d "$SRC/patched/hardware" ]; then
  mkdir -p "$SRC/patched" && cp -a "$SRC/stock/hardware" "$SRC/patched/"
  (cd "$SRC/patched" && patch -p1 < "$REPO/patches/0001-holybro-uart-r39.2.1.patch")
fi
K=$SRC/kernel/kernel/kernel-noble

build() {  # build <nv-public dir> <dts name> <out.dtb>
  local N=$1
  cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "$N" -I "$N/include" -I "$N/include/nvidia-oot" -I "$N/include/kernel" \
    -I "$K/include" -I "$K/scripts/dtc/include-prefixes" -I "$N/nv-platform" -I "$N/nv-soc" \
    "$N/nv-platform/$2.dts" -o "$3.pre"
  "$DTC" -q -@ -I dts -O dtb -o "$3" "$3.pre"
  rm -f -- "$3.pre"
}

# Sanity check: the stock build must reproduce NVIDIA's shipped DTB byte for byte
ref=tegra234-p3768-0000+p3767-0000-nv-super
ship=$L4T/kernel/dtb/$ref.dtb; [ -f "$ship.stock" ] && ship=$ship.stock
build "$SRC/stock/hardware/nvidia/t23x/nv-public" $ref "$SRC/$ref.stock-build.dtb"
cmp -s "$SRC/$ref.stock-build.dtb" "$ship" || { echo "stock build differs from NVIDIA's $ref.dtb; aborting"; exit 1; }
echo "stock build matches NVIDIA's shipped $ref.dtb"

for sku in 0000 0001 0003 0004 0005; do
  for v in nv nv-super; do
    name=tegra234-p3768-0000+p3767-$sku-$v
    build "$SRC/patched/hardware/nvidia/t23x/nv-public" "$name" "$REPO/dtb/$name.dtb"
    echo "built dtb/$name.dtb"
  done
done
(cd "$REPO/dtb" && sha256sum *.dtb > SHA256SUMS)
