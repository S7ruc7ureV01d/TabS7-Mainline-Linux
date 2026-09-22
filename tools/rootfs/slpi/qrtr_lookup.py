#!/usr/bin/env python3
"""Minimal qrtr-lookup: list every service registered with the QRTR name
service (no qrtr-tools needed). Service 400 is SNS_CLIENT, the Snapdragon
Sensor Core endpoint libssc talks to."""
import select
import socket
import struct

AF_QIPCRTR = 42
QRTR_TYPE_NEW_SERVER = 4
QRTR_TYPE_NEW_LOOKUP = 10
QRTR_PORT_CTRL = 0xfffffffe
LOCAL_NODE = 1

NAMES = {15: "ssctl (v1)", 24: "wlfw", 43: "ssctl", 51: "?", 64: "tftp",
         66: "servreg-notif", 69: "?", 400: "SNS_CLIENT (sensors)"}

s = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM)
# control packet: type, service, instance, node, port (all le32)
s.sendto(struct.pack("<5I", QRTR_TYPE_NEW_LOOKUP, 0, 0, 0, 0),
         (LOCAL_NODE, QRTR_PORT_CTRL))
while select.select([s], [], [], 2)[0]:
    data, _ = s.recvfrom(64)
    typ, svc, inst, node, port = struct.unpack("<5I", data[:20])
    if typ != QRTR_TYPE_NEW_SERVER:
        continue
    if svc == inst == node == 0:
        break  # end of list
    print(f"service {svc:5d} ({NAMES.get(svc, '?')}) ver {inst & 0xff} "
          f"inst {inst >> 8} @ node {node} port {port}")
