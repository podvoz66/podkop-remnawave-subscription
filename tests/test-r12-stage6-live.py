"""Local-only regression for fixture startup/TLS/DNS. No external connection."""
import http.client, importlib.util, os, socket, ssl, struct, subprocess, tempfile, time, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('fixture',ROOT/'scripts/lab/r12-stage6-fixture.py')
f=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(f)
def port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]
class Integration(unittest.TestCase):
    def test_server_starts_and_validates_real_http_tls_udp_tcp(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',directory+'/server.key','-out',directory+'/server.crt','-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            hp,tp,dp=port(),port(),port()
            with open(directory+'/out','w+') as out:
                proc=subprocess.Popen(['/usr/bin/python3',str(ROOT/'scripts/lab/r12-stage6-fixture.py'),'serve',directory,'--bind','127.0.0.1','--http-port',str(hp),'--https-port',str(tp),'--dns-port',str(dp)],stdout=out,stderr=out)
                try:
                    until=time.monotonic()+5
                    while time.monotonic()<until:
                        out.seek(0); content=out.read()
                        if 'R12_FIXTURE_READY' in content: break
                        if proc.poll() is not None: self.fail(content)
                        time.sleep(.05)
                    else: self.fail('startup timeout')
                    for conn in [http.client.HTTPConnection('127.0.0.1',hp,timeout=2),http.client.HTTPSConnection('127.0.0.1',tp,timeout=2,context=ssl.create_default_context(cafile=directory+'/server.crt'))]:
                        conn.request('GET','/r12/localregression'); response=conn.getresponse()
                        self.assertEqual(response.status,200); self.assertEqual(response.read(),b'R12 localregression\n'); conn.close()
                    request=struct.pack('!6H',12,0x100,1,0,0,0)+b'\x03one\x03r12\x04test\x00'+struct.pack('!HH',1,1)
                    for typ in [socket.SOCK_DGRAM,socket.SOCK_STREAM]:
                        with socket.socket(socket.AF_INET,typ) as s:
                            s.settimeout(2); s.connect(('127.0.0.1',dp))
                            if typ==socket.SOCK_DGRAM: s.send(request); reply=s.recv(4096)
                            else: s.sendall(struct.pack('!H',len(request))+request); reply=f.recv_exact(s,struct.unpack('!H',f.recv_exact(s,2))[0])
                            self.assertEqual(reply,f.dns_reply(request)[0])
                finally:
                    proc.terminate(); proc.wait(timeout=3)
if __name__=='__main__': unittest.main()
