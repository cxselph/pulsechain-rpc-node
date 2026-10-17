#!/usr/bin/env python3
"""Ask a DNS server one question (stdlib only): dnscheck.py SERVER NAME [TYPE]

Prints "<RCODE> <answer> ..." e.g. "NOERROR 100.101.102.103" or "REFUSED".
Exit 0 if the server answered at all, 1 if it didn't.
"""
import random
import socket
import struct
import sys

RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}
TYPES = {"A": 1, "AAAA": 28}


def query(server, name, qtype="A", timeout=3.0):
    qid = random.randint(0, 0xFFFF)
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)  # RD set
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
    packet = header + qname + struct.pack(">HH", TYPES[qtype], 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        s.sendto(packet, (server, 53))
        data, _ = s.recvfrom(4096)
    rid, flags, qd, an, _, _ = struct.unpack(">HHHHHH", data[:12])
    if rid != qid:
        raise RuntimeError("mismatched reply id")
    pos = 12
    for _ in range(qd):  # skip the question
        while data[pos] != 0:
            pos += data[pos] + 1
        pos += 5
    answers = []
    for _ in range(an):
        if data[pos] & 0xC0 == 0xC0:
            pos += 2
        else:
            while data[pos] != 0:
                pos += data[pos] + 1
            pos += 1
        rtype, _, _, rdlen = struct.unpack(">HHIH", data[pos:pos + 10])
        pos += 10
        rdata = data[pos:pos + rdlen]
        pos += rdlen
        if rtype == 1 and rdlen == 4:
            answers.append(socket.inet_ntoa(rdata))
        elif rtype == 28 and rdlen == 16:
            answers.append(socket.inet_ntop(socket.AF_INET6, rdata))
    return RCODES.get(flags & 0xF, str(flags & 0xF)), answers


if __name__ == "__main__":
    try:
        rcode, answers = query(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "A")
    except Exception as exc:  # noqa: BLE001
        print(f"NO-ANSWER {exc}")
        sys.exit(1)
    print(" ".join([rcode, *answers]))
