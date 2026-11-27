#!/usr/bin/env python3
"""Compare a k7cap pcapng (two interfaces) against tcpdump reference pcaps, one per port.

cmp_pcapng.py CAP.pcapng IFACE DST_MAC REF.pcap [IFACE DST_MAC REF.pcap ...]
  IFACE 0 = SFP A, 1 = SFP B. Frames on IFACE whose destination MAC is DST_MAC are
  compared in order with REF (tcpdump of the sender), byte for byte without the FCS.
Also checks every FCS (the capture must be made with --keep-fcs) and reports the
epb_dropcount / epb_flags options and the FPGA-minus-sender timestamp spread.
"""
import struct, sys, zlib


def read_pcapng(path):
    d = open(path, 'rb').read()
    o, ifaces, pkts = 0, [], []
    while o + 12 <= len(d):
        bt, bl = struct.unpack_from('<II', d, o)
        if bl < 12 or o + bl > len(d):
            raise SystemExit(f'bad block at {o}')
        body = d[o + 8:o + bl - 4]
        if bt == 0x0A0D0D0A:
            assert struct.unpack_from('<I', body, 0)[0] == 0x1A2B3C4D, 'not little endian'
        elif bt == 1:
            link, _, snap = struct.unpack_from('<HHI', body, 0)
            opts, q = {}, 8
            while q + 4 <= len(body):
                c, n = struct.unpack_from('<HH', body, q)
                if c == 0:
                    break
                opts[c] = body[q + 4:q + 4 + n]
                q += 4 + ((n + 3) & ~3)
            ifaces.append(dict(link=link, snap=snap, name=opts.get(2, b'').decode(),
                               tsres=opts.get(9, b'\x06')[0], fcslen=opts.get(13, b'\x00')[0]))
        elif bt == 6:
            ifid, th, tl, cl, ol = struct.unpack_from('<IIIII', body, 0)
            data = body[20:20 + cl]
            q = 20 + ((cl + 3) & ~3)
            flags, drops = 0, 0
            while q + 4 <= len(body):
                c, n = struct.unpack_from('<HH', body, q)
                if c == 0:
                    break
                v = body[q + 4:q + 4 + n]
                if c == 2:
                    flags = struct.unpack('<I', v)[0]
                elif c == 4:
                    drops = struct.unpack('<Q', v)[0]
                q += 4 + ((n + 3) & ~3)
            ts = ((th << 32) | tl) * 10 ** -ifaces[ifid]['tsres']
            pkts.append(dict(ifid=ifid, ts=ts, data=data, olen=ol, flags=flags, drops=drops))
        o += bl
    return ifaces, pkts


def read_pcap(path):
    d = open(path, 'rb').read()
    magic = struct.unpack_from('<I', d, 0)[0]
    ns = magic == 0xa1b23c4d
    o, out = 24, []
    while o + 16 <= len(d):
        s, f, cl, wl = struct.unpack_from('<IIII', d, o)
        o += 16
        out.append((s + f * (1e-9 if ns else 1e-6), d[o:o + cl]))
        o += cl
    return out


cap = sys.argv[1]
ifaces, pkts = read_pcapng(cap)
print('interfaces:', ', '.join(f"{i}={x['name']} (tsres 1e-{x['tsres']}, fcslen {x['fcslen']})" for i, x in enumerate(ifaces)))
for i in range(len(ifaces)):
    pp = [p for p in pkts if p['ifid'] == i]
    fcs_ok = sum(1 for p in pp if len(p['data']) == p['olen'] and
                 zlib.crc32(p['data'][:-4]) & 0xffffffff == struct.unpack('<I', p['data'][-4:])[0])
    print(f"iface {i}: {len(pp)} packets, FCS ok {fcs_ok}/{len(pp)}, bad-FCS flagged {sum(1 for p in pp if p['flags'] >> 24 & 1)}, "
          f"dropcount total {sum(p['drops'] for p in pp)}")
args = sys.argv[2:]
for k in range(0, len(args), 3):
    ifid, dst, ref = int(args[k]), bytes.fromhex(args[k + 1].replace(':', '')), args[k + 2]
    mine = [p for p in pkts if p['ifid'] == ifid and p['data'][:6] == dst]
    theirs = read_pcap(ref)
    n = min(len(mine), len(theirs))
    same = sum(1 for a, b in zip(mine, theirs) if a['data'][:-4] == b[1])
    lat = sorted((a['ts'] - b[0]) * 1e6 for a, b in zip(mine, theirs))
    print(f"iface {ifid} to {args[k + 1]}: k7cap {len(mine)}, tcpdump {len(theirs)}, byte-identical {same}/{n}"
          + (f", FPGA ts - sender ts: min {lat[0]:.1f} med {lat[len(lat) // 2]:.1f} max {lat[-1]:.1f} us" if lat else ''))
