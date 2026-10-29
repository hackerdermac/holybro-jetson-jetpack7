#!/bin/bash
# Run ON THE JETSON after flashing: check the Holybro UARTs and the Ethernet link to the Pixhawk.
# Changes nothing persistent (the 192.168.128.1 address is removed again).
# Serial traffic only shows if the Pixhawk sends MAVLink on that port (TELEM2 -> ttyTHS1 at 921600).
set -u
IF=${IF:-$(ip -br link | awk '$1 ~ /^en/ {print $1; exit}')}
PX4_IP=${PX4_IP:-192.168.128.3}
AGENT_IP=${AGENT_IP:-192.168.128.1}
sudo -v || exit 1

echo "===== device tree ====="
for n in serial@3100000 serial@3110000 serial@3140000; do
  p=/proc/device-tree/bus@0/$n
  echo "$n status=$(tr -d '\0' < $p/status) compat=$(tr '\0' ' ' < $p/compatible) dma=$([ -e $p/dmas ] && echo yes || echo no)"
done

echo "===== Ethernet ($IF, Pixhawk $PX4_IP) ====="
sudo ip addr add "$AGENT_IP/24" dev "$IF"
ping -c3 -W1 "$PX4_IP" >/dev/null && echo "Pixhawk answers ping" || echo "Pixhawk NOT reachable"
sudo timeout 7 python3 -I - "$IF" "$PX4_IP" <<'EOF'
import socket, sys, time, collections
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0800)); s.bind((sys.argv[1], 0)); s.settimeout(0.5)
c, end = collections.Counter(), time.time() + 6
while time.time() < end:
    try: f = s.recv(2048)
    except socket.timeout: continue
    if f[23] != 17 or socket.inet_ntoa(f[26:30]) != sys.argv[2]: continue
    ihl = (f[14] & 15) * 4
    c[(socket.inet_ntoa(f[30:34]), int.from_bytes(f[16+ihl:18+ihl], "big"))] += 1
for (d, p), n in c.items(): print(f"  {n:4d} UDP packets -> {d}:{p}")
if not c: print("  no UDP traffic from the Pixhawk")
EOF
sudo ip addr del "$AGENT_IP/24" dev "$IF"

echo "===== serial ====="
sudo python3 -I - <<'EOF'
import os, termios, time, select
for dev in ("/dev/ttyTHS1", "/dev/ttyTHS3"):
    for baud, code in ((57600, termios.B57600), (921600, termios.B921600)):
        fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        a = termios.tcgetattr(fd); a[0] = a[1] = a[3] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL; a[4] = a[5] = code
        termios.tcsetattr(fd, termios.TCSANOW, a); termios.tcflush(fd, termios.TCIFLUSH)
        buf, end = b"", time.time() + 2.5
        while time.time() < end:
            if select.select([fd], [], [], 0.2)[0]:
                try: buf += os.read(fd, 4096)
                except BlockingIOError: pass
        os.close(fd)
        print(f"  {dev} @ {baud:>6}: {len(buf):6d} bytes{'  MAVLink2' if buf.count(bytes([0xfd])) > 3 else ''}")
EOF
