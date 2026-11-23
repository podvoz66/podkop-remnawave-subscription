#!/usr/bin/python3
"""Second independent, nonrecursive LAB DNS upstream on 5353. No external queries."""
import json, socketserver, struct, sys, threading, time

def exact(sock,n):
    data=b''
    while len(data)<n:
        part=sock.recv(n-len(data))
        if not part: raise ValueError('EOF')
        data+=part
    return data

def reply(data):
    if len(data)<12: raise ValueError('header')
    ident,flags,count,an,ns,ar=struct.unpack('!6H',data[:12])
    if count!=1 or flags&0x8000: raise ValueError('question')
    pos=12; labels=[]
    while True:
        size=data[pos]; pos+=1
        if not size: break
        if size>63 or pos+size>len(data): raise ValueError('label')
        labels.append(data[pos:pos+size].decode('ascii')); pos+=size
    name='.'.join(labels)
    if name!='openwrt.org' and not name.endswith('.r12.test'): raise ValueError('name')
    end=pos+4
    if end>len(data) or an or ns or ar>1: raise ValueError('question shape')
    typ,cls=struct.unpack('!HH',data[pos:end])
    if typ not in (1,28) or cls!=1: raise ValueError('type/class')
    if ar:
        if end+11>len(data) or data[end:end+3]!=b'\0\0\x29': raise ValueError('OPT')
        if end+11+struct.unpack('!H',data[end+9:end+11])[0]!=len(data): raise ValueError('OPT length')
    elif end!=len(data): raise ValueError('trailing bytes')
    answer=b'\xc0\x0c'+struct.pack('!HHIH',1,1,0,4)+b'\x0a\xfd\xcb\x01'
    return struct.pack('!6H',ident,0x8180,1,int(typ==1),0,0)+data[12:end]+(answer if typ==1 else b''),name

def serve(directory):
    lock=threading.Lock()
    def answer(data,kind):
        result,name=reply(data)
        with lock,open(directory+'/primary-dns.jsonl','a') as log:
            log.write(json.dumps({'time':time.time(),'name':name,'kind':kind})+'\n')
        return result
    class UDP(socketserver.BaseRequestHandler):
        def handle(self):
            try: self.request[1].sendto(answer(self.request[0],'udp'),self.client_address)
            except (OSError,ValueError,IndexError,UnicodeError): pass
    class TCP(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(3)
            try:
                size=struct.unpack('!H',exact(self.request,2))[0]
                if size>4096: return
                data=answer(exact(self.request,size),'tcp')
                self.request.sendall(struct.pack('!H',len(data))+data)
            except (OSError,ValueError,IndexError,UnicodeError): pass
    class TCPServer(socketserver.ThreadingTCPServer): allow_reuse_address=True; daemon_threads=True
    class UDPServer(socketserver.ThreadingUDPServer): allow_reuse_address=True; daemon_threads=True
    with UDPServer(('10.253.203.1',5353),UDP) as udp, TCPServer(('10.253.203.1',5353),TCP) as tcp:
        threading.Thread(target=udp.serve_forever,daemon=True).start()
        print('R12_PRIMARY_DNS_READY',flush=True); tcp.serve_forever()
if __name__=='__main__': serve(sys.argv[1])
