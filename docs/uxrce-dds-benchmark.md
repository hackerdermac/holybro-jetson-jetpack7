# uXRCE-DDS link benchmark, and why the UARTs use DMA

Holybro's JetPack 6.2.2 patch turns off DMA on UARTA (`ttyTHS1`, Pixhawk TELEM2), and its UARTB (`ttyTHS3`) also
runs without DMA. This port first copied that. A benchmark of the PX4 uXRCE-DDS link showed PIO mode has no benefit and
breaks down above 921600 baud, so the port now keeps NVIDIA's stock DMA on UARTA and gives UARTB DMA too.

## Setup

- **Pixhawk:** Pixhawk 6X, PX4 v1.17.0 (`px4_fmu-v6x_default`), PX4's default DDS topic set, disarmed on the bench.
- **Jetson:** Orin NX 16GB, JetPack 7.2.1 with this repo's DTBs.
- **ROS 2:** Jazzy (Fast DDS), Micro XRCE-DDS Agent v2.4.3 (the version PX4 lists for Jazzy), `px4_msgs` `release/1.17`.
- **Links:** PX4's DDS client only supports UDP and serial, not TCP.
  - UDP: Ethernet, PX4 192.168.128.3 → agent 192.168.128.1:8888, `UXRCE_DDS_CFG = 1000`.
  - Serial: PX4 TELEM2 ↔ Jetson `/dev/ttyTHS1`, `UXRCE_DDS_CFG = 102`, `SER_TEL2_BAUD` per row.
- **Method** ([`bench/`](../bench/)): `run_round.sh` starts the agent, waits for the PX4 session and runs `uxrce_bench.py` for 30 s
  after a 3 s warm-up. It records:
  - the rates of all `/fmu/out` topics
  - the worst gap in the 100 Hz/50 Hz topics
  - the round trip of a `VehicleCommand` with `MAV_CMD_USER_1` (PX4 rejects it as unsupported, so it's harmless) to its
    `VehicleCommandAck`, at 10 Hz
  - the agent's CPU load (100% = one core)
- **PIO vs DMA:** "PIO" is Holybro's device tree. "DMA" is the same with UARTA's `dmas` restored and UARTB on GPC-DMA request 9.

## Results

| Link | msg/s | payload kB/s | 100 Hz topics (min Hz) | worst gap ms | RTT p50 ms | RTT p99 ms | RTT max ms | cmds lost | agent CPU |
|---|---|---|---|---|---|---|---|---|---|
| **UDP, Ethernet** | 395.1 | 37.0 | 100.0 | 28.1 | **12.2** | **20.4** | 21.2 | 0 | **2.9%** |
| Serial 921600, PIO | 393.9 | 36.9 | 99.6 | 58.9 | 13.7 | 23.7 | 26.6 | 0 | 6.0% |
| Serial 921600, DMA | 395.0 | 37.0 | 100.0 | 31.9 | 16.1 | 32.2 | 34.4 | 0 | 3.3% |
| Serial 1.5 M, PIO | 387.4 | 35.9 | 97.3 | 78.7 | 115.5 | 223.9 | 226.8 | 0 | 5.2% |
| Serial 1.5 M, DMA | 395.1 | 37.1 | 100.0 | 31.7 | 14.7 | 25.3 | 26.1 | 0 | 3.2% |
| Serial 3 M, PIO | 389.3 | 36.5 | 98.6 | 379.8 | 413.5 | 426.1 | 426.4 | 0 | 5.1% |
| Serial 3 M, DMA | 387.9 | 36.6 | 96.2 | 83.3 | 311.5 | 421.0 | 426.5 | 0 | 3.4% |

Per-topic data: [`bench/results/`](../bench/results/).

## Findings

- **UDP over Ethernet is best on every metric:**
  - lowest round trip
  - smallest gaps
  - lowest CPU
  - no serial setup
- **The default topic set needs only ~37 kB/s,** so bandwidth isn't the limit; latency and robustness are.
- **921600:** both modes work. DMA halves the agent's CPU (3.3% vs 6.0%) and the worst topic gap (32 vs 59 ms).
- **1.5 Mbaud:** PIO drops messages and the median round trip rises to 115 ms. DMA delivers full rates at 15 ms.
- **3 Mbaud:** too slow either way, with round trips of 300–420 ms. DMA shrinks the gaps (83 vs 380 ms) but not the latency, which
  points at the link (no flow control on this wiring, or the Pixhawk side) rather than the Jetson UART mode.
- **PIO had no advantage in any round.**

Recommendation: **UDP over Ethernet** for PX4 ↔ Jetson DDS. For serial, use 921600 or 1.5 Mbaud with DMA; avoid 3 Mbaud.

Caveats:
- One 30 s run per configuration, so round-trip differences of a few ms are noise. The round trip includes PX4 commander's
  processing time.
- UARTB's DMA request number (9) isn't in any NVIDIA source file. It follows the Tegra234 GPC-DMA UART numbering
  (UARTA 8, UARTD 19, UARTE 20 are in `tegra234.dtsi`).
- UARTB ran with DMA in the benchmark boot: its kernel log has no PIO messages and it joins the GPC-DMA IOMMU group. But no
  benchmark traffic ran over UARTB; on the tested board it's not wired to TELEM1 or TELEM2.

## Reproducing

On the Jetson, with ROS 2 Jazzy, the agent in `PATH` and `px4_msgs` built in `~/ros2_ws`, and the `bench/` folder copied there:

```bash
bench/run_round.sh udp-ethernet udp
```

```bash
bench/run_round.sh serial-921600 serial /dev/ttyTHS1 921600
```

Switching the Pixhawk between UDP and TELEM2 and setting the baud rate can be done over its USB port with
`bench/px4params.py` (pymavlink). For example, `px4params.py /dev/ttyACM0 set UXRCE_DDS_CFG=102`, then `... reboot`. Back up
the parameters first with `px4params.py /dev/ttyACM0 dump backup.params`.
