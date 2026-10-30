# PX4 parameter tool over MAVLink (USB): dump all params to a QGC-style .params file, or set params.
#   px4params.py /dev/ttyACM0 dump out.params
#   px4params.py /dev/ttyACM0 set NAME=VALUE [NAME=VALUE ...]   (ints/floats inferred from current type)
#   px4params.py /dev/ttyACM0 reboot
import sys, time, struct
from pymavlink import mavutil

INT_TYPES = {mavutil.mavlink.MAV_PARAM_TYPE_INT8, mavutil.mavlink.MAV_PARAM_TYPE_UINT8,
             mavutil.mavlink.MAV_PARAM_TYPE_INT16, mavutil.mavlink.MAV_PARAM_TYPE_UINT16,
             mavutil.mavlink.MAV_PARAM_TYPE_INT32, mavutil.mavlink.MAV_PARAM_TYPE_UINT32}

def decode(p):
    if p.param_type in INT_TYPES:
        return struct.unpack("<i", struct.pack("<f", p.param_value))[0]
    return p.param_value

def read_all(m):
    m.mav.param_request_list_send(m.target_system, m.target_component)
    params, total, last = {}, None, time.time()
    while time.time() - last < 3 and (total is None or len(params) < total):
        p = m.recv_match(type="PARAM_VALUE", blocking=True, timeout=1)
        if p:
            last = time.time(); total = p.param_count; params[p.param_id] = p
    return params, total

m = mavutil.mavlink_connection(sys.argv[1], baud=115200)
m.wait_heartbeat(timeout=10)
cmd = sys.argv[2]

if cmd == "dump":
    params, total = read_all(m)
    with open(sys.argv[3], "w") as f:
        f.write("# Onboard parameters for Vehicle 1\n# Vehicle-Id Component-Id Name Value Type\n")
        for k in sorted(params):
            p = params[k]
            v = decode(p)
            f.write(f"{m.target_system}\t{m.target_component}\t{k}\t{v if p.param_type in INT_TYPES else repr(float(v))}\t{p.param_type}\n")
    print(f"saved {len(params)}/{total} params to {sys.argv[3]}")

elif cmd == "set":
    params, _ = read_all(m)
    for kv in sys.argv[3:]:
        k, v = kv.split("=", 1)
        p = params[k]
        if p.param_type in INT_TYPES:
            raw = struct.unpack("<f", struct.pack("<i", int(v)))[0]
        else:
            raw = float(v)
        m.mav.param_set_send(m.target_system, m.target_component, k.encode(), raw, p.param_type)
        ack = m.recv_match(type="PARAM_VALUE", blocking=True, timeout=3)
        while ack and ack.param_id != k:
            ack = m.recv_match(type="PARAM_VALUE", blocking=True, timeout=3)
        print(f"{k} = {decode(ack) if ack else 'NO ACK'}")

elif cmd == "reboot":
    m.mav.command_long_send(m.target_system, m.target_component,
                            mavutil.mavlink.MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN, 0, 1, 0, 0, 0, 0, 0, 0)
    print("reboot sent")
