#!/usr/bin/python3
"""Synthetic VLESS/TLS endpoint; forwards ONLY to the offline fixture in its netns.

Not a Reality implementation. No production credentials or external DNS resolution.
UUID is read from a local 0600 file, never printed. Run with an external timeout.
"""
import argparse, json, os, select, socket, socketserver, ssl, struct, time, uuid

def exact(sock, size):
    data = b''
    while len(data) < size:
        part = sock.recv(size-len(data))
        if not part: raise EOFError()
        data += part
    return data

def serve(directory, bind='10.253.203.1', port=10443, cert_directory='/root/r12-stage6'):
    credential = directory+'/uuid'
    if os.stat(credential).st_mode & 0o077: raise ValueError('credential permissions')
    expected = uuid.UUID(open(credential).read().strip()).bytes
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_directory+'/server.crt',cert_directory+'/server.key')
    def log(**fields):
        with open(directory+'/vless.jsonl','a') as out:
            out.write(json.dumps(dict(time=time.time(), **fields))+'\n')
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(8)
            try:
                with context.wrap_socket(self.request, server_side=True) as client:
                    version = exact(client,1)
                    if version != b'\0' or exact(client,16) != expected:
                        log(event='AUTH_REJECT'); return
                    extra = exact(client,1)[0]
                    exact(client,extra)
                    command = exact(client,1)[0]
                    dest_port = struct.unpack('!H',exact(client,2))[0]
                    kind = exact(client,1)[0]
                    if kind == 1: host = socket.inet_ntoa(exact(client,4))
                    elif kind == 2: host = exact(client,exact(client,1)[0]).decode('ascii')
                    else: raise ValueError('address type')
                    if host in ('fixture.r12.test','vpn.r12.test','vptcp.r12.test','usa.r12.test') or host.endswith('.vpn.r12.test'): host = bind
                    if host != bind or dest_port not in (53,8080,8443,8001):
                        log(event='DEST_DENIED',port=dest_port); return
                    if command not in (1,2) or (command == 2 and dest_port != 53):
                        log(event='COMMAND_DENIED'); return
                    log(event='VLESS_ACCEPT',port=dest_port,command=command)
                    client.sendall(b'\0\0')
                    if command == 2:
                        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as upstream:
                            upstream.settimeout(3)
                            while True:
                                size = struct.unpack('!H',exact(client,2))[0]
                                if size > 4096: raise ValueError('DNS size')
                                upstream.sendto(exact(client,size),(host,dest_port))
                                reply = upstream.recv(4096)
                                client.sendall(struct.pack('!H',len(reply))+reply)
                    else:
                        with socket.create_connection((host,dest_port),3) as upstream:
                            deadline = time.monotonic()+60
                            while time.monotonic()<deadline:
                                ready = [client] if client.pending() else select.select([client,upstream],[],[],3)[0]
                                if not ready: continue
                                for source in ready:
                                    data = source.recv(16384)
                                    if not data: return
                                    (upstream if source is client else client).sendall(data)
            except (OSError, EOFError, ValueError, UnicodeError):
                log(event='CONNECTION_CLOSED')
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True
    with Server((bind,port),Handler) as server:
        print('R12_VLESS_TLS_READY',flush=True)
        server.serve_forever()

if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('directory')
    p.add_argument('--bind',choices=['10.253.203.1','127.0.0.1'],default='10.253.203.1')
    p.add_argument('--port',type=int,default=10443)
    p.add_argument('--cert-directory',default='/root/r12-stage6'); a=p.parse_args()
    serve(a.directory,a.bind,a.port,a.cert_directory)
