#!/usr/bin/python3
"""Offline synthetic HTTP/TLS/DNS fixture. Never queries upstream DNS or the internet."""
import argparse, http.server, ipaddress, json, os, re, socket, socketserver, ssl, struct, threading, time

def dns_reply(data):
    if len(data)<12: raise ValueError('short header')
    ident,flags,qd,an,ns,ar=struct.unpack('!6H',data[:12])
    if qd!=1 or flags & 0x8000: raise ValueError('not one question')
    pos=12; labels=[]
    while True:
        if pos>=len(data): raise ValueError('short name')
        size=data[pos]; pos+=1
        if not size: break
        if size>63 or pos+size>len(data): raise ValueError('bad label')
        labels.append(data[pos:pos+size].decode('ascii')); pos+=size
    end=pos+4
    if end>len(data) or an or ns or ar>1: raise ValueError('bad question')
    if ar:
        # Accept one EDNS0 OPT, strip it from this synthetic response. No upstream.
        if end+11>len(data) or data[end:end+3]!=b'\0\0\x29': raise ValueError('bad OPT')
        size=struct.unpack('!H',data[end+9:end+11])[0]
        if end+11+size!=len(data): raise ValueError('bad OPT length')
    elif end!=len(data): raise ValueError('trailing data')
    typ,cls=struct.unpack('!HH',data[pos:pos+4]); name='.'.join(labels)
    if typ not in (1,28) or cls!=1 or not re.fullmatch(r'[a-z0-9-]+\.r12\.test',name): raise ValueError('nonfixture question')
    answer=b'\xc0\x0c'+struct.pack('!HHIH',1,1,0,4)+ipaddress.ip_address('10.253.203.1').packed
    return struct.pack('!6H',ident,0x8180,1,int(typ==1),0,0)+data[12:end]+(answer if typ==1 else b''),name

def recv_exact(s,n):
    result=b''
    while len(result)<n:
        chunk=s.recv(n-len(result))
        if not chunk: raise ValueError('short TCP reply')
        result+=chunk
    return result

def probe(proto,token):
    if not re.fullmatch('[a-z0-9-]+',token): raise ValueError('bad token')
    ident=int.from_bytes(os.urandom(2),'big'); name=token+'.r12.test'
    question=b''.join(bytes([len(x)])+x.encode() for x in name.split('.'))+b'\0'+struct.pack('!HH',1,1)
    request=struct.pack('!6H',ident,0x100,1,0,0,0)+question
    with socket.socket(socket.AF_INET,socket.SOCK_STREAM if proto=='tcp' else socket.SOCK_DGRAM) as s:
        s.settimeout(3); s.connect(('10.253.203.1',53))
        if proto=='tcp':
            s.sendall(struct.pack('!H',len(request))+request); reply=recv_exact(s,struct.unpack('!H',recv_exact(s,2))[0])
        else:
            s.send(request); reply=s.recv(4096)
    expected,_=dns_reply(request)
    if reply!=expected: raise ValueError('DNS identity/question/answer validation failed')
    print('DNS_'+proto.upper()+'_PASS '+name+' A=10.253.203.1')

def serve(directory,bind,http_port,https_port,dns_port):
    lock=threading.Lock()
    def log(kind,peer,token):
        with lock,open(directory+'/requests.jsonl','a',encoding='utf8') as f:
            f.write(json.dumps({'kind':kind,'peer':peer,'token':token,'time':time.time()})+'\n'); f.flush()
    class HTTP(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if not re.fullmatch(r'/r12/[a-z0-9-]+',self.path): self.send_error(404); return
            kind='https' if isinstance(self.connection,ssl.SSLSocket) else 'http'
            token=self.path.split('/')[-1]; log(kind,self.client_address[0],token)
            body=('R12 '+token+'\n').encode(); self.send_response(200)
            self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self,*args): pass
    class UDP(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                reply,name=dns_reply(self.request[0]); log('dns-udp',self.client_address[0],name)
                self.request[1].sendto(reply,self.client_address)
            except (ValueError,UnicodeError): pass
    class TCP(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(3)
            try:
                size=struct.unpack('!H',recv_exact(self.request,2))[0]
                if size>4096: return
                reply,name=dns_reply(recv_exact(self.request,size)); log('dns-tcp',self.client_address[0],name)
                self.request.sendall(struct.pack('!H',len(reply))+reply)
            except (ValueError,OSError,UnicodeError): pass
    class TCPServer(socketserver.ThreadingTCPServer): allow_reuse_address=True; daemon_threads=True
    class UDPServer(socketserver.ThreadingUDPServer): allow_reuse_address=True; daemon_threads=True
    http_service=http.server.ThreadingHTTPServer((bind,http_port),HTTP)
    https=http.server.ThreadingHTTPServer((bind,https_port),HTTP)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(directory+'/server.crt',directory+'/server.key')
    https.socket=context.wrap_socket(https.socket,server_side=True)
    servers=[http_service,https,UDPServer((bind,dns_port),UDP),TCPServer((bind,dns_port),TCP)]
    for server in servers: threading.Thread(target=server.serve_forever,daemon=True).start()
    print('R12_FIXTURE_READY',flush=True)
    while True: time.sleep(3600)

if __name__=='__main__':
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest='action',required=True)
    a=sub.add_parser('serve'); a.add_argument('directory'); a.add_argument('--bind',default='10.253.203.1')
    a.add_argument('--http-port',type=int,default=8080); a.add_argument('--https-port',type=int,default=8443); a.add_argument('--dns-port',type=int,default=53)
    a=sub.add_parser('probe'); a.add_argument('proto',choices=['udp','tcp']); a.add_argument('token')
    a=p.parse_args()
    if a.action=='serve': serve(a.directory,a.bind,a.http_port,a.https_port,a.dns_port)
    else: probe(a.proto,a.token)
