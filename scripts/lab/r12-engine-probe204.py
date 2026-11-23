#!/usr/bin/python3
"""Run inside r12-lan; real router DNS and HTTP/TLS with independent WAN receipts."""
import argparse, ipaddress, json, os, pathlib, re, socket, struct, subprocess, time

def exact(sock,n):
    result=b''
    while len(result)<n:
        part=sock.recv(n-len(result))
        if not part: raise ValueError('short DNS TCP')
        result+=part
    return result

def dns(name,tcp=False):
    ident=int.from_bytes(os.urandom(2),'big')
    question=b''.join(bytes([len(p)])+p.encode() for p in name.split('.'))+b'\0\0\1\0\1'
    request=struct.pack('!6H',ident,0x100,1,0,0,0)+question
    with socket.socket(socket.AF_INET,socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as s:
        s.settimeout(12); s.connect(('10.253.202.1',53))
        if tcp:
            s.sendall(struct.pack('!H',len(request))+request)
            reply=exact(s,struct.unpack('!H',exact(s,2))[0])
        else: s.send(request); reply=s.recv(4096)
    rid,flags,qd,an,_,_=struct.unpack('!6H',reply[:12])
    if rid!=ident or flags&15 or qd!=1 or not an or reply[12:12+len(question)]!=question:
        raise ValueError(f'DNS {name}: rcode={flags&15} qd={qd} an={an} id_ok={rid==ident} question_ok={reply[12:12+len(question)]==question}')
    pos=12+len(question)
    for _ in range(an):
        if reply[pos]&0xc0==0xc0: pos+=2
        else:
            while reply[pos]: pos+=1+reply[pos]
            pos+=1
        typ,cls,ttl,length=struct.unpack('!HHIH',reply[pos:pos+10]); pos+=10
        if typ==1 and cls==1 and length==4:
            address=str(ipaddress.ip_address(reply[pos:pos+4]))
            if address!='10.253.203.1' and ipaddress.ip_address(address) not in ipaddress.ip_network('198.18.0.0/15'):
                raise ValueError('unexpected fixture address')
            return address
        pos+=length
    raise ValueError('no A answer')

def probe(token,mode):
    if not re.fullmatch('[a-z0-9-]{1,80}',token): raise ValueError('token')
    result={'id':token,'expected_path':mode,'time':time.time()}
    for version in ('-4','-6'):
        if subprocess.check_output(['ip',version,'route','show','default']).strip(): raise ValueError('external default')
    addresses=[dns('vpn.r12.test'),dns('vptcp.r12.test',True)]
    plain=[dns(token+'-plain.r12.test'),dns(token+'-plain-tcp.r12.test',True)]
    if plain!=['10.253.203.1','10.253.203.1']: raise ValueError('upstream DNS answer')
    tls_address=dns('fixture.r12.test')
    result['dns_udp']=addresses[0]; result['dns_tcp']=addresses[1]; result['upstream_dns_udp_tcp']=plain
    for proto,host,port,addr in [('http','vpn.r12.test',8080,addresses[0]),('https','fixture.r12.test',8443,tls_address)]:
        command=['curl','--noproxy','*','--fail','--silent','--show-error','--connect-timeout','3','--max-time','12','--resolve',f'{host}:{port}:{addr}']
        if proto=='https': command+=['--cacert','/root/r12-stage6/server.crt']
        command+=[f'{proto}://{host}:{port}/r12/{token}-{proto}']
        reply=subprocess.check_output(command,stderr=subprocess.PIPE,timeout=15)
        if reply!=f'R12 {token}-{proto}\n'.encode(): raise ValueError('HTTP body')
        receipts=[json.loads(line) for line in pathlib.Path('/root/r12-stage6/requests.jsonl').read_text().splitlines()]
        matching=[r for r in receipts if r.get('token')==token+'-'+proto]
        peer='10.253.203.1' if mode=='VPN' else '10.253.203.2'
        if not matching or matching[-1]['peer']!=peer: raise ValueError(proto+' independent path mismatch')
        result[proto]={'status':200,'peer':peer,'tls_verified':proto=='https'}
    result['result']='PASS'
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('id'); p.add_argument('mode',choices=['VPN','DIRECT']); a=p.parse_args()
    try: print(json.dumps(probe(a.id,a.mode)),flush=True)
    except Exception as e:
        print(json.dumps({'id':a.id,'result':'FAIL','reason':type(e).__name__+': '+str(e)[:160]}),flush=True)
        raise SystemExit(1)
