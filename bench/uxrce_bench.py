#!/usr/bin/env python3
"""Benchmark one PX4 uXRCE-DDS link from the ROS 2 side (run while the agent is up).

Measures, over a fixed window:
  - per-topic message rate, inter-arrival jitter and gaps for every /fmu/out topic
  - total throughput (messages/s, serialized payload bytes/s)
  - round-trip latency: VehicleCommand (MAV_CMD_USER_1, unsupported -> harmless) on /fmu/in/vehicle_command,
    answered by commander on /fmu/out/vehicle_command_ack
  - CPU usage of the MicroXRCEAgent process

Usage: uxrce_bench.py <label> [seconds] [rtt_hz]   -> prints a summary and writes <label>.json
"""
import json, os, statistics, sys, time
import importlib
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy
from rclpy.serialization import serialize_message

PX4_QOS = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                     history=HistoryPolicy.KEEP_LAST, depth=10)
MAV_CMD_USER_1 = 31010


def msg_class(type_str):
    pkg, _, name = type_str.split("/")
    return getattr(importlib.import_module(f"{pkg}.msg"), name)


def agent_cpu_ticks():
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            if b"MicroXRCEAgent" not in open(f"/proc/{pid}/cmdline", "rb").read():
                continue
            f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
            return int(f[11]) + int(f[12])
        except OSError:
            continue
    return None


class Bench(Node):
    def __init__(self, rtt_hz):
        super().__init__("uxrce_bench")
        self.arrivals, self.nbytes, self.subs = {}, {}, []
        self.rtt, self.sent = [], {}
        self.cmd_cls = self.ack_topic = self.cmd_pub = None
        topics = {}
        for _ in range(20):  # wait for discovery
            topics = {n: t[0] for n, t in self.get_topic_names_and_types() if n.startswith("/fmu/")}
            if any(n.startswith("/fmu/out/") for n in topics):
                break
            rclpy.spin_once(self, timeout_sec=0.5)
        for name, typ in sorted(topics.items()):
            if not name.startswith("/fmu/out/"):
                continue
            self.arrivals[name], self.nbytes[name] = [], 0
            self.subs.append(self.create_subscription(msg_class(typ), name, self._cb(name), PX4_QOS))
            if "vehicle_command_ack" in name:
                self.ack_topic = name
        cmd_topic = next((n for n in topics if n.startswith("/fmu/in/vehicle_command") and "mode" not in n), None)
        if cmd_topic and self.ack_topic and rtt_hz > 0:
            self.cmd_cls = msg_class(topics[cmd_topic])
            self.cmd_pub = self.create_publisher(self.cmd_cls, cmd_topic, PX4_QOS)
            self.create_timer(1.0 / rtt_hz, self._send_cmd)
        self.seq = 0
        self.lost = 0

    def _cb(self, name):
        def cb(msg):
            t = time.monotonic()
            self.arrivals[name].append(t)
            self.nbytes[name] += len(serialize_message(msg))
            if name == self.ack_topic and msg.command == MAV_CMD_USER_1 and self.sent:
                # the ack doesn't echo our sequence number: match it to the oldest outstanding command
                self.rtt.append((t - self.sent.pop(next(iter(self.sent)))) * 1000)
        return cb

    def _send_cmd(self):
        now = time.monotonic()
        for k in [k for k, ts in self.sent.items() if now - ts > 1.0]:  # count as lost, stop matching
            self.lost += 1
            del self.sent[k]
        self.seq = (self.seq + 1) % 2**31
        c = self.cmd_cls()
        c.timestamp = int(self.get_clock().now().nanoseconds / 1000)
        c.command = MAV_CMD_USER_1
        c.param1 = float(self.seq)
        c.target_system, c.target_component = 1, 1
        c.source_system, c.source_component = 255, 190
        c.from_external = True
        self.sent[self.seq] = time.monotonic()
        self.cmd_pub.publish(c)


def pct(v, p):
    return sorted(v)[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))] if v else None


def main():
    label = sys.argv[1]
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30
    rtt_hz = float(sys.argv[3]) if len(sys.argv) > 3 else 10
    rclpy.init()
    n = Bench(rtt_hz)
    if not n.arrivals:
        print("no /fmu/out topics discovered - is the agent connected?")
        sys.exit(1)
    warm = time.monotonic() + 3
    while time.monotonic() < warm:
        rclpy.spin_once(n, timeout_sec=0.05)
    for k in n.arrivals:
        n.arrivals[k].clear(); n.nbytes[k] = 0
    n.rtt.clear(); n.sent.clear(); n.lost = 0
    hz = os.sysconf("SC_CLK_TCK")
    c0, t0 = agent_cpu_ticks(), time.monotonic()
    while time.monotonic() - t0 < secs:
        rclpy.spin_once(n, timeout_sec=0.05)
    t1, c1 = time.monotonic(), agent_cpu_ticks()
    dur = t1 - t0
    lost_rtt = n.lost + len([k for k, ts in n.sent.items() if t1 - ts > 1.0])

    topics = {}
    for name, ts in n.arrivals.items():
        d = [(b - a) * 1000 for a, b in zip(ts, ts[1:])]
        topics[name] = {
            "msgs": len(ts), "rate_hz": round(len(ts) / dur, 2), "bytes_s": round(n.nbytes[name] / dur),
            "gap_max_ms": round(max(d), 1) if d else None,
            "jitter_ms": round(statistics.pstdev(d), 2) if len(d) > 1 else None,
        }
    res = {
        "label": label, "seconds": round(dur, 1),
        "total_msgs_s": round(sum(len(t) for t in n.arrivals.values()) / dur, 1),
        "total_bytes_s": round(sum(n.nbytes.values()) / dur),
        "rtt_ms": {"n": len(n.rtt), "lost": lost_rtt,
                   "p50": pct(n.rtt, 50), "p95": pct(n.rtt, 95), "p99": pct(n.rtt, 99),
                   "max": max(n.rtt) if n.rtt else None} if n.cmd_pub else None,
        "agent_cpu_pct": round((c1 - c0) / hz / dur * 100, 1) if c0 is not None and c1 is not None else None,
        "topics": topics,
    }
    json.dump(res, open(f"{label}.json", "w"), indent=1)
    print(f"== {label}: {res['total_msgs_s']} msg/s, {res['total_bytes_s']/1000:.1f} kB/s payload, "
          f"agent CPU {res['agent_cpu_pct']}%")
    if res["rtt_ms"]:
        r = res["rtt_ms"]
        f = lambda x: f"{x:.1f}" if x is not None else "-"
        print(f"   RTT cmd->ack: n={r['n']} lost={r['lost']} p50={f(r['p50'])} p95={f(r['p95'])} "
              f"p99={f(r['p99'])} max={f(r['max'])} ms")
    for name, t in sorted(topics.items(), key=lambda x: -x[1]["rate_hz"]):
        print(f"   {t['rate_hz']:8.1f} Hz  {t['bytes_s']/1000:7.1f} kB/s  gap_max {t['gap_max_ms']} ms  {name}")
    n.destroy_node(); rclpy.shutdown()


if __name__ == "__main__":
    main()
