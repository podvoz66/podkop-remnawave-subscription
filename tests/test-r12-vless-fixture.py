"""Real loopback TLS/VLESS forwarding and authentication/egress restrictions; NOT a LAB verdict."""
import http.server, json, os, socket, ssl, struct, subprocess, tempfile, threading, time, unittest, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class FixtureTest(unittest.TestCase):
    def test_tls_vless_http_bad_auth_and_external_destination_denied(self):
        with tempfile.TemporaryDirectory() as d:
            identity=uuid.uuid4()
            Path(d+'/uuid').write_text(str(identity)); os.chmod(d+'/uuid',0o600)
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',d+'/server.key','-out',d+'/server.crt','-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            class HTTP(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200); self.end_headers(); self.wfile.write(b'vless-real-http')
                def log_message(self,*args): pass
            with http.server.HTTPServer(('127.0.0.1',8080),HTTP) as service:
                threading.Thread(target=service.serve_forever,daemon=True).start()
                with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
                with open(d+'/output','w+') as output:
                    proc=subprocess.Popen(['/usr/bin/python3',str(ROOT/'scripts/lab/r12-vless-fixture.py'),d,'--bind','127.0.0.1','--port',str(port),'--cert-directory',d],stdout=output,stderr=output)
                    try:
                        for _ in range(100):
                            output.seek(0)
                            if 'R12_VLESS_TLS_READY' in output.read(): break
                            if proc.poll() is not None: self.fail('fixture startup failed')
                            time.sleep(.03)
                        else: self.fail('fixture timeout')
                        context=ssl.create_default_context(cafile=d+'/server.crt')
                        def connect(user,host):
                            s=context.wrap_socket(socket.create_connection(('127.0.0.1',port),2),server_hostname='localhost')
                            s.settimeout(3)
                            s.sendall(b'\0'+user.bytes+b'\0\1'+struct.pack('!H',8080)+b'\1'+socket.inet_aton(host))
                            return s
                        with connect(identity,'127.0.0.1') as s:
                            self.assertEqual(s.recv(2),b'\0\0')
                            s.sendall(b'GET /r12/test HTTP/1.0\r\nHost: localhost\r\n\r\n')
                            result=b''
                            while True:
                                part=s.recv(8192)
                                if not part: break
                                result+=part
                            self.assertIn(b'200 OK',result); self.assertIn(b'vless-real-http',result)
                        with connect(uuid.uuid4(),'127.0.0.1') as s: self.assertEqual(s.recv(2),b'')
                        with connect(identity,'8.8.8.8') as s: self.assertEqual(s.recv(2),b'')
                        events=[json.loads(x)['event'] for x in Path(d+'/vless.jsonl').read_text().splitlines()]
                        self.assertIn('VLESS_ACCEPT',events); self.assertIn('AUTH_REJECT',events); self.assertIn('DEST_DENIED',events)
                    finally: proc.terminate(); proc.wait(timeout=3); service.shutdown()
if __name__=='__main__': unittest.main()
