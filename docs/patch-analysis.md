# Holybro's JetPack 6.2.2 patch and the R39.2.1 port

## What `holybro_jp622` contains

Holybro's [flashing guide](https://docs.holybro.com/autopilot/pixhawk-baseboards/pixhawk-jetson-baseboard/flashing-guide)
has you extract the `holybro_jp622` archive into `Linux_for_Tegra/` of L4T R36.5.0. It contains 12 files.
Each was compared with the stock R36.5.0 file; the DTBs were decompiled with `dtc -s`, ignoring phandle numbering:

| File | vs. stock R36.5.0 |
|---|---|
| `p3768-0000-p3767-0000-a0.conf` | +`OVERLAY_DTB_FILE+=",tegra234-p3767-camera-p3768-imx219-dual.dtbo";` |
| `kernel/dtb/tegra234-p3767-camera-p3768-imx219-dual.dtbo` | identical |
| `kernel/dtb/tegra234-p3768-0000+p3767-{0000,0001,0003,0004,0005}-nv{,-super}.dtb` | same change in all 10, see below |

The DTBs carry `nvidia,dtsfilename = ".../nv-platform/tegra234-p3768-0000+p3767-xxxx-nv-common.dtsi"`, so the change
was made in that file. Decompiled, it amounts to:

```
aliases { serial3 = "/bus@0/serial@3110000"; };        /* + label uartb */
serial@3100000 { /delete-property/ dmas; /delete-property/ dma-names; };
serial@3110000 { compatible = "nvidia,tegra194-hsuart"; reset-names = "serial"; status = "okay"; };
```

So:
- **UARTA** (`ttyTHS1`, the link to Pixhawk TELEM2) runs in PIO mode.
- **UARTB** (`ttyTHS3`) is enabled.

The MB1 pinmux needs no change: `tegra234-mb1-bct-pinmux-p3767-dp-a03.dtsi` already sets `uart2_{tx,rx,rts,cts}_px4…px7`
to `uartb`.

## Deviation from Holybro: the UARTs keep DMA

The port at first copied the change above exactly. It now differs on purpose:
- **UARTA:** the `/delete-property/ dmas` / `dma-names` lines are dropped, so UARTA keeps NVIDIA's `<&gpcdma 8>`.
- **UARTB:** gets `dmas = <&gpcdma 9>, <&gpcdma 9>`, `dma-names = "rx", "tx"` and `iommus = <&smmu_niso0 TEGRA234_SID_GPCDMA>`
  (the SMMU stream UARTA and UARTE use).
- **Request number:** 9 follows the Tegra234 GPC-DMA UART numbering; `tegra234.dtsi` has UARTA 8, UARTD 19, UARTE 20.

Holybro doesn't say why it disabled DMA. The [uXRCE-DDS benchmark](uxrce-dds-benchmark.md) found PIO mode worse at every
baud rate tested: higher CPU at 921600, and dropped messages with ~115 ms round trips at 1.5 Mbaud, where DMA runs at full rate.
To get Holybro's behaviour back, add the two `/delete-property/` lines to `serial@3100000` and drop the three DMA
properties from `serial@3110000`.

## Why it ports to R39.2.1 unchanged

- `nv-platform/tegra234-p3768-0000+p3767-xxxx-nv-common.dtsi` still exists in R39.2.1. NVIDIA's R36.5→R39.2.1 changes to it
  (audio, SPI cells, display ordering) don't touch the UART nodes.
- The UART definitions are the same in both releases:
  - `tegra234.dtsi` defines `uarta` with `dmas = <&gpcdma 8>, <&gpcdma 8>`.
  - `tegra234-soc-overlay.dtsi` defines `serial@3110000` as disabled `nvidia,tegra234-uart`.
  - `tegra234-p3768-0000+p3767.dtsi` switches `uarta` to `nvidia,tegra194-hsuart`.
- NVIDIA's AGX Orin devkit (`tegra234-p3737-0000+p3701-xxxx-nv-common.dtsi`) enables UARTB in R39.2.1 with the same snippet.
- The R39.2.1 kernel (`kernel-noble`, 6.8.12) `drivers/tty/serial/serial-tegra.c` still matches `nvidia,tegra194-hsuart`.
  Without a `dmas` property it uses PIO, as on 5.15.
- The R39.2.1 MB1 pinmux file is byte-identical to R36.5.0's.
- R39.2.1 ships the same `tegra234-p3767-camera-p3768-imx219-dual.dtbo` (identical to R36.5.0's). Its board conf has the same
  `OVERLAY_DTB_FILE` line after which Holybro's line goes.

## Verification

- `scripts/build-dtbs.sh` builds `tegra234-p3768-0000+p3767-0000-nv-super.dtb` from unpatched R39.2.1 sources first. It aborts
  unless the result is byte-identical to NVIDIA's shipped DTB, which confirms the cpp/dtc build reproduces NVIDIA's.
- The patched DTBs differ from NVIDIA's R39.2.1 DTBs only in the UARTB node (enabled as hsuart, with DMA and `iommus`) and
  the `serial3`/`uartb` entries. UARTA is byte-for-byte NVIDIA's. The UART nodes match the DTB used in the DMA benchmark.

## Board config used for flashing

- `jetson-orin-nano-devkit-super` → `p3768-0000-p3767-0000-super.conf`, which sources `p3768-0000-p3767-0000-a0.conf`.
- For P3767-0000 it uses `DTB_FILE=tegra234-p3768-0000+p3767-0000-nv-super.dtb`.
- The flash command is the one from Holybro's guide, with R39.2.1's file names (NVMe via `l4t_initrd_flash.sh`).
