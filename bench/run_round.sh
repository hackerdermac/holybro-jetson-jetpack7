#!/bin/bash
# One benchmark round on the Jetson: start MicroXRCEAgent on a transport, wait for the PX4 session,
# run uxrce_bench.py, stop the agent.
#   run_round.sh <label> udp
#   run_round.sh <label> serial <dev> <baud>
# Results go to ~/bench/<label>.json and <label>.agent.log.
set -eo pipefail
BENCH_DIR=$(cd "$(dirname "$0")" && pwd)
source /opt/ros/jazzy/setup.bash
source ~/ros2_ws/install/setup.bash
export PATH=$HOME/.local/bin:$PATH LD_LIBRARY_PATH=$HOME/.local/lib:${LD_LIBRARY_PATH:-}
label=$1; kind=$2
mkdir -p ~/bench && cd ~/bench
case $kind in
  udp)    args=(udp4 -p 8888) ;;
  serial) args=(serial --dev "$3" -b "$4") ;;
  *) echo "usage: $0 <label> udp | serial <dev> <baud>"; exit 2 ;;
esac
MicroXRCEAgent "${args[@]}" -v 4 > "$label.agent.log" 2>&1 &
agent=$!
trap 'kill $agent 2>/dev/null; wait $agent 2>/dev/null' EXIT
for _ in $(seq 1 30); do
  grep -q "session established" "$label.agent.log" && break
  sleep 1
done
if ! grep -q "session established" "$label.agent.log"; then
  echo "== $label: no PX4 session within 30 s"; exit 1
fi
sleep 8   # let PX4 create all its topics
python3 "$BENCH_DIR/uxrce_bench.py" "$label" "${SECS:-30}" "${RTT_HZ:-10}"
