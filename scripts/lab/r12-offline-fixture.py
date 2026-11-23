#!/usr/bin/python3
"""LAB204 WAN-only packages/health/synthetic subscription fixture. No upstream."""
import argparse, http.server, json, os, pathlib, re, ssl, threading, time

def serve(directory):
    root=pathlib.Path(directory)
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path=self.path.split('?',1)[0]
            with open(root/'offline.jsonl','a') as log:
                log.write(json.dumps({'time':time.time(),'path':path,'peer':self.client_address[0]})+'\n')
            if path=='/probe64k': body=b'R'*65536
            elif path=='/subscription/valid': body=(root/'subscription.txt').read_bytes()
            elif path=='/subscription/main-only': body=(root/'subscription.txt').read_bytes().splitlines()[0]+b'\n'
            elif path=='/subscription/empty': body=b''
            elif path=='/subscription/malformed': body=b'<html>invalid subscription</html>'
            elif path=='/subscription/500': self.send_error(500); return
            elif path=='/subscription/timeout': time.sleep(30); body=b''
            elif path=='/uuid': body=(root/'uuid').read_bytes()
            elif path=='/ca.crt': body=pathlib.Path('/root/r12-stage6/server.crt').read_bytes()
            elif re.fullmatch(r'/[a-zA-Z0-9_.+-]+\.(apk|adb|tar|sh|py|txt|json)',path):
                file=root/path[1:]
                if not file.is_file() or file.is_symlink(): self.send_error(404); return
                body=file.read_bytes()
            else: self.send_error(404); return
            self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError): pass
        def log_message(self,*args): pass
    http_service=http.server.ThreadingHTTPServer(('10.253.203.1',8001),Handler)
    https=http.server.ThreadingHTTPServer(('10.253.203.1',8002),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain('/root/r12-stage6/server.crt','/root/r12-stage6/server.key')
    https.socket=context.wrap_socket(https.socket,server_side=True)
    threading.Thread(target=http_service.serve_forever,daemon=True).start()
    print('R12_OFFLINE_FIXTURE_READY',flush=True)
    https.serve_forever()

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('directory'); a=p.parse_args(); serve(a.directory)
