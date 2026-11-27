#!/usr/bin/env python3
"""Software FPGA: RoCE v2 RDMA READ requester over raw Ethernet frames. Run as root on the requester host.
fakefpga.py IFACE SRC_IP DST_IP DST_MAC PARAMS_FILE OUTDIR"""
import socket,struct,sys,time,zlib,os,json
ifc,sip,dip,dmac,pf,out=sys.argv[1:7]
P={}
for l in open(pf):
    f=l.split()
    if len(f)==2: P[f[0]]=int(f[1])
smac=open(f'/sys/class/net/{ifc}/address').read().strip()
mac=lambda s: bytes.fromhex(s.replace(':',''))
def ipcsum(h):
    s=sum(struct.unpack('!10H',h)); s=(s&0xffff)+(s>>16); s=(s&0xffff)+(s>>16); return ~s&0xffff
def icrc(ip_on):                      # ip_on = IP header .. end of payload, without ICRC
    b=bytearray(ip_on); b[1]=0xff; b[8]=0xff; b[10:12]=b'\xff\xff'; b[26:28]=b'\xff\xff'; b[32]=0xff
    return struct.pack('<I',zlib.crc32(b'\xff'*8+bytes(b))&0xffffffff)
ipid=0
def read_req(qpn,psn,va,rkey,n,bad=False):
    global ipid; ipid+=1
    bth=struct.pack('!BBHII',0x0c,0x40,0xffff,qpn&0xffffff,0x80000000|(psn&0xffffff))
    pl=bth+struct.pack('!QII',va,rkey,n)
    udp=struct.pack('!HHHH',0xC000|(qpn&0x3fff),4791,8+len(pl)+4,0)
    h=struct.pack('!BBHHHBBH4s4s',0x45,0,20+8+len(pl)+4,ipid,0x4000,64,17,0,socket.inet_aton(sip),socket.inet_aton(dip))
    h=h[:10]+struct.pack('!H',ipcsum(h))+h[12:]
    body=h+udp+pl; c=icrc(body)
    if bad: c=bytes([c[0]^1])+c[1:]
    return mac(dmac)+mac(smac)+b'\x08\x00'+body+c
def parse(f):
    if len(f)<58 or f[12:14]!=b'\x08\x00' or f[23]!=17 or f[36:38]!=struct.pack('!H',4791): return None
    if f[26:30]!=socket.inet_aton(dip): return None
    ln=struct.unpack('!H',f[16:18])[0]; ip=f[14:14+ln]
    d=dict(op=ip[28],pad=(ip[29]>>4)&3,dqpn=int.from_bytes(ip[33:36],'big'),psn=int.from_bytes(ip[37:40],'big'),icrc_ok=icrc(ip[:-4])==ip[-4:])
    o=40
    if d['op'] in(0x0d,0x0f,0x10,0x11): d['syn']=ip[40]; d['msn']=int.from_bytes(ip[41:44],'big'); o=44
    d['data']=ip[o:len(ip)-4-d['pad']]; return d
s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(3)); s.bind((ifc,0)); s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,8<<20)
log=[]
def send(f,tag): log.append((time.time(),'req',tag,f)); s.send(f)
def recv(tag,want_psn_last=None,t=0.5):
    r=[]; end=time.time()+t
    while time.time()<end:
        s.settimeout(max(0.001,end-time.time()))
        try: f,a=s.recvfrom(9000)
        except socket.timeout: break
        if a[2]==4: continue          # our own outgoing frame
        d=parse(f)
        if d is None: continue
        log.append((time.time(),'rsp',tag,f)); r.append(d)
        if d['op']==0x11 or (want_psn_last is not None and d['psn']==want_psn_last): break
    return r
MTU=1024
def pat(off,n):
    a=off&~3; b=b''.join(struct.pack('<I',((i*2654435761)&0xffffffff)^0xA5A50000) for i in range(a//4,(off+n+3)//4)); return b[off-a:off-a+n]
npk=lambda n:max(1,(n+MTU-1)//MTU)
def expops(n):
    k=npk(n); return [0x10] if k==1 else [0x0d]+[0x0e]*(k-2)+[0x0f]
res=[]
def rec(name,ok,info=''): res.append((name,bool(ok),info)); print(('PASS ' if ok else 'FAIL ')+name,info,flush=True)
def good(r,psn,off,n,first=True):
    k=npk(n)
    return (len(r)==k and [d['psn'] for d in r]==[(psn+i)&0xffffff for i in range(k)] and [d['op'] for d in r]==expops(n)
        and all(d['icrc_ok'] and d['dqpn']==P['peer_qpn0'] for d in r) and b''.join(d['data'] for d in r)==pat(off,n))
psn=P['psn']; q=P['qpn0']; A=P['addr']; K=P['rkey']
desc=lambda r:' '.join(f"{d['op']:#04x}/psn{d['psn']:#x}/{len(d['data'])}B"+(f"/syn{d['syn']:#x}" if 'syn' in d else '')+('' if d['icrc_ok'] else '/BADICRC') for d in r) or 'no reply'
for off,n in[(0,8),(64,64),(0,1024),(0,1025),(100,7),(3,1),(128,4096),(1,3001),(0,16384)]:
    t=f'read_off{off}_len{n}'; send(read_req(q,psn,A+off,K,n),t); r=recv(t,psn+npk(n)-1)
    ok=good(r,psn,off,n); rec(t,ok,desc(r) if len(r)<5 else f'{len(r)} packets')
    if not r: break
    psn+=npk(n)
if res[0][2]!='no reply':
    t='duplicate_request'; p0=psn; send(read_req(q,psn,A,K,64),t); r=recv(t,psn); send(read_req(q,psn,A,K,64),t); r2=recv(t,psn); rec(t,good(r,p0,0,64) and good(r2,p0,0,64),desc(r2)); psn+=1
    t='bad_icrc_dropped'; send(read_req(q,psn,A,K,64,bad=True),t); r=recv(t,psn); rec(t,not r,desc(r))
    t='psn_gap_nak'; send(read_req(q,psn+5,A,K,64),t); r=recv(t); rec(t,len(r)==1 and r[0]['op']==0x11 and r[0]['syn']==0x60 and r[0]['psn']==psn,desc(r))
    t='resume_after_nak'; send(read_req(q,psn,A+256,K,512),t); r=recv(t,psn); rec(t,good(r,psn,256,512),desc(r)); psn+=1
    t='window_4x4096'; p0=psn
    for i in range(4): send(read_req(q,p0+4*i,A+4096*i,K,4096),t)
    r=recv(t,p0+15); rec(t,len(r)==16 and all(good(r[4*i:4*i+4],p0+4*i,4096*i,4096) for i in range(4)),f'{len(r)} packets'); psn+=16
    t='partial_reissue'; p0=psn; send(read_req(q,p0,A+8192,K,4096),t); r=recv(t,p0+3); a=len(r)==4
    send(read_req(q,p0+2,A+8192+2048,K,2048),t); r=recv(t,p0+3); rec(t,a and [d['psn'] for d in r]==[p0+2,p0+3] and r[-1]['op']==0x0f and all(d['icrc_ok'] for d in r) and b''.join(d['data'] for d in r)==pat(8192+2048,2048),desc(r))  # NIC may start a partial reissue with MIDDLE; psn+=4
    q1=P['qpn1']; t='bad_rkey_nak'; send(read_req(q1,P['psn'],A,K^0xff00,64),t); r=recv(t); rec(t,len(r)==1 and r[0]['op']==0x11 and r[0]['syn']==0x62,desc(r))
os.makedirs(out,exist_ok=True)
with open(f'{out}/golden.pcap','wb') as f:
    f.write(struct.pack('<IHHiIII',0xa1b2c3d4,2,4,0,0,65535,1))
    for ts,_,_,b in log: f.write(struct.pack('<IIII',int(ts),int(ts%1*1e6),len(b),len(b))+b)
with open(f'{out}/golden.txt','w') as f:
    f.write('# dir test hex(frame without FCS)\n'); [f.write(f'{d} {t} {b.hex()}\n') for _,d,t,b in log]
json.dump(dict(params=P,src_ip=sip,dst_ip=dip,src_mac=smac,dst_mac=dmac,results=res),open(f'{out}/manifest.json','w'),indent=1)
print(sum(x[1] for x in res),'of',len(res),'passed;',len(log),'frames')
