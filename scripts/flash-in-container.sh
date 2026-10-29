#!/bin/bash
# Runs inside the Ubuntu 22.04 container started by scripts/flash.sh (/work = WORK, /repo = this repo).
# NVIDIA's flash tools support Ubuntu 20.04/22.04 hosts only; the container makes any newer host work.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export USER=root  # NVIDIA flash scripts check $USER, which docker leaves unset

echo "=== [1/6] container packages ==="
apt-get update -qq
apt-get install -y -qq sudo usbutils lbzip2 bzip2 tar python3 kmod iproute2 whiptail >/dev/null

cd /work/Linux_for_Tegra
if [ ! -d rootfs/usr ]; then
  echo "=== [2/6] extract rootfs ==="
  tar -I lbzip2 -xpf ../dl/Tegra_Linux_Sample-Root-Filesystem_R39.2.1_aarch64.tbz2 -C rootfs/
fi

echo "=== [3/6] flash prerequisites + apply_binaries ==="
./tools/l4t_flash_prerequisites.sh
if [ ! -f .applied ]; then
  rm -f rootfs/dev/random rootfs/dev/urandom  # leftovers from an interrupted run
  # Register qemu-aarch64 with the host kernel (until reboot) so the arm64 rootfs chroot can run
  mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
  if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' > /proc/sys/fs/binfmt_misc/register
  fi
  ./apply_binaries.sh
  touch .applied
fi

echo "=== [4/6] verify Holybro port (DTBs + board conf) ==="
for f in /repo/dtb/*.dtb; do
  cmp -s "$f" "kernel/dtb/$(basename "$f")" || { echo "kernel/dtb/$(basename "$f") is not the Holybro build; run scripts/prepare-l4t.sh"; exit 1; }
done
grep -q 'imx219-dual.dtbo' p3768-0000-p3767-0000-a0.conf || { echo "board conf lacks the Holybro overlay line; run scripts/prepare-l4t.sh"; exit 1; }
echo "Holybro DTBs and board conf in place"

echo "=== [5/6] default user (skips the first-boot setup wizard) ==="
if [ ! -f .user_created ]; then
  read -rp "Username for the Jetson [holybro]: " U; U=${U:-holybro}
  read -rsp "Password for $U: " P; echo
  ./tools/l4t_create_default_user.sh -u "$U" -p "$P" -n ubuntu
  unset P; touch .user_created
fi

echo "=== [6/6] flash ==="
modprobe nfsd 2>/dev/null || true
until lsusb | grep -qE "0955:7[3-6]23 "; do
  echo "Waiting for Jetson in recovery mode (DIP switch to REC, USB-C to this PC, power-cycle)..."; sleep 5
done
lsusb | grep 0955
ONLY=""; [ -f tools/kernel_flash/images/external/system.img ] && ONLY="--flash-only"  # reuse images from an earlier run
./tools/kernel_flash/l4t_initrd_flash.sh $ONLY --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
  --showlogs --network usb0 jetson-orin-nano-devkit-super internal
echo "===== FLASH DONE ====="
