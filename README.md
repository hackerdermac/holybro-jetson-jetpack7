# holybro-jetson-jetpack7

Flash **JetPack 7.2.1 (Jetson Linux R39.2.1, Ubuntu 24.04, kernel 6.8)** to a Jetson Orin NX on the
[Holybro Pixhawk Jetson baseboard](https://docs.holybro.com/autopilot/pixhawk-baseboards/pixhawk-jetson-baseboard/flashing-guide),
with Holybro's JetPack 6.2.2 board patch ported to R39.2.1.

> **Not supported by Holybro.** Holybro supports JetPack 5.1.2–6.0 and 6.2.2 on this baseboard. This repo is an
> unofficial port. It was tested on one Orin NX 16GB; see [Tested](#tested). If something doesn't work, reflash
> JetPack 6.2.2 with Holybro's guide. Recovery mode always works.

## What the port contains

Holybro's JetPack 6.2.2 patch (`holybro_jp622`) turned out to be a small change. The full analysis is in
[docs/patch-analysis.md](docs/patch-analysis.md).

| Change | Effect |
|---|---|
| UARTA `serial@3100000` without DMA | `/dev/ttyTHS1` (Pixhawk TELEM2) runs in PIO mode |
| UARTB `serial@3110000` enabled | additional `/dev/ttyTHS3` |
| `OVERLAY_DTB_FILE += imx219-dual.dtbo` in the board conf | dual IMX219 camera overlay loaded by default |

There are no bootloader or pinmux changes; NVIDIA's stock pinmux already routes UARTB.

- [`patches/0001-holybro-uart-r39.2.1.patch`](patches/0001-holybro-uart-r39.2.1.patch): the device-tree change against R39.2.1 sources.
- [`dtb/`](dtb/): the 10 patched Orin NX/Nano DTBs, prebuilt. Only the Holybro change differs from NVIDIA's DTBs; [`scripts/build-dtbs.sh`](scripts/build-dtbs.sh) rebuilds them and checks that.

## Requirements

- **Linux PC with Docker.** NVIDIA's tools need an Ubuntu 20.04/22.04 host, so the flash runs in an `ubuntu:22.04` container. Tested on an Ubuntu 26.04 host.
- **USB-C cable** from the Jetson's USB-C port to the PC.
- **Downloads from NVIDIA** (not included here; NVIDIA's license doesn't allow redistribution). Save them **directly into this repo folder**, next to this README, and keep these names (git ignores them):

| File | Size | Needed for |
|---|---|---|
| [Jetson_Linux_R39.2.1_aarch64.tbz2](https://developer.download.nvidia.com/embedded/L4T/r39_Release_v2.1/release/Jetson_Linux_R39.2.1_aarch64.tbz2) | 1.29 GB | flashing |
| [Tegra_Linux_Sample-Root-Filesystem_R39.2.1_aarch64.tbz2](https://developer.download.nvidia.com/embedded/L4T/r39_Release_v2.1/release/Tegra_Linux_Sample-Root-Filesystem_R39.2.1_aarch64.tbz2) | 2.02 GB | flashing |
| [public_sources.tbz2](https://developer.download.nvidia.com/embedded/L4T/r39_Release_v2.1/sources/public_sources.tbz2) | 310 MB | only for rebuilding the DTBs |

## Flashing

Run the scripts from the repo folder. They extract the BSP to `Linux_for_Tegra/` and the sources to `src/` inside it. Plan for
about 30 GB of free space (`Linux_for_Tegra/` is 27 GB after a flash). The flash log is `flash.log`, with the password masked.

```bash
scripts/prepare-l4t.sh      # extract the BSP, install the Holybro DTBs and board-conf line
```

```bash
scripts/flash.sh            # flash in the container
```

`flash.sh` takes about 30–45 minutes the first time. It asks for:

1. **sudo** on the PC.
2. **Username and password** for the Jetson. This skips the first-boot wizard, so it works headless.
3. **NVIDIA's license agreement.**
4. **Recovery mode** on the Jetson: switch power off, set the baseboard DIP switch to **REC**, connect USB-C, power on. `lsusb` shows `0955:7323` (Orin NX 16GB) or `0955:7423/7523/7623`.

The flash ends with `Flash is successful`. Then set the DIP switch **back from REC** and power-cycle. The Jetson gets
its address by DHCP on the baseboard Ethernet port.

A second run reuses the images it built (`--flash-only`) and finishes in about 10 minutes.

### Pitfalls the scripts handle

| Problem | Symptom | Fix in the scripts |
|---|---|---|
| NetworkManager on the PC manages the Jetson's USB network link | Flash fails mid-copy: "device cannot mount the NFS server" | `nm-unmanage-jetson-usb.sh` runs during the flash |
| No qemu binfmt for aarch64 on the host | `chroot: failed to run command 'dpkg': Exec format error` | registered from the container (until the next reboot) |
| `$USER` unset in Docker | "requires root privilege" | `USER=root` |
| `whiptail` missing in the container | license prompt fails | installed |
| Interrupted `apply_binaries` | `mknod: …/dev/random: File exists` | leftovers removed |

The flash tool's "VPN detected" warning was harmless here (Proton VPN with kill switch). It's only a hint.

## After flashing

Run on the Jetson to check the ports and the Pixhawk link (needs sudo; changes nothing persistent):

```bash
scripts/test-pixhawk-links.sh
```

It checks:
- **Device tree:** ttyTHS1 and ttyTHS3 without DMA.
- **Ethernet:** gives the Jetson a temporary 192.168.128.1 and pings the Pixhawk at 192.168.128.3 (adjust with `PX4_IP` / `AGENT_IP`). It also counts the Pixhawk's DDS and MAVLink packets.
- **Serial:** listens on ttyTHS1 and ttyTHS3. Traffic only shows when the Pixhawk sends MAVLink on that port. On the tested board, **TELEM2 is ttyTHS1 at 921600**.

Notes:
- The NVIDIA apt sources point to the `r39.2` channel.
- Ubuntu 24.04 means ROS 2 **Jazzy**; Humble isn't available.
- The DTBs live in the QSPI and kernel partitions. An NVIDIA package update can replace them with stock ones, so check `ttyTHS3` after updates.

## Tested

Orin NX 16GB (P3767-0000) on a Holybro Pixhawk Jetson baseboard with a Pixhawk 6X (PX4 1.16), 2026-10-30:

| Check | Result |
|---|---|
| Boot from NVMe, `jetson-orin-nano-devkit-super`, 40 W mode | ✅ |
| ttyTHS1 / ttyTHS3 in PIO mode, ttyTHS2 with DMA (as with Holybro's 6.2.2 patch) | ✅ |
| ttyTHS1 ↔ Pixhawk TELEM2: MAVLink 2 at 921600 | ✅ |
| ttyTHS3 | driver ✅, wiring unknown (no traffic from TELEM1/TELEM2) |
| Ethernet (RTL8111, `r8168`), Pixhawk at 192.168.128.3: ping, DDS to :8888, MAVLink on :14550 | ✅ |
| USB hubs, NVMe, CAN (`mttcan`) detected | ✅ |
| CAN traffic, cameras, USB devices | not tested |

Boot log errors that also appear on Holybro's JetPack 6.2.2: IMX219 probe errors with no cameras connected, `fusb301` (not on this baseboard).

## Repository layout

```
patches/   device-tree patch for L4T R39.2.1
dtb/       prebuilt patched DTBs + SHA256SUMS
scripts/   prepare, build, flash, NetworkManager watcher, link test
docs/      analysis of Holybro's JetPack 6.2.2 patch and the port

Local only (git-ignored):
*.tbz2             the NVIDIA downloads
Linux_for_Tegra/   extracted BSP + rootfs, created by prepare-l4t.sh / flash.sh
src/               extracted sources, created by build-dtbs.sh
flash.log
```

## License

- **Scripts** (`scripts/`) and documentation: MIT, see [LICENSE](LICENSE).
- **Device-tree patch and DTBs** (`patches/`, `dtb/`): GPL-2.0-only, the license of NVIDIA's device-tree sources they're derived from. See [LICENSES/GPL-2.0-only.txt](LICENSES/GPL-2.0-only.txt).

NVIDIA's BSP, rootfs and sources and Holybro's patch archive aren't included. They're under their own licenses;
download them from the links above.

Not affiliated with NVIDIA or Holybro. Jetson and JetPack are trademarks of NVIDIA Corporation.
