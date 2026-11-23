import importlib.util
from pathlib import Path
import struct
import unittest
spec=importlib.util.spec_from_file_location('fixture',Path(__file__).resolve().parents[1]/'scripts/lab/r12-stage6-fixture.py')
fixture=importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
class DNSCodec(unittest.TestCase):
    def query(self,name='unique.r12.test',typ=1):
        q=b''.join(bytes([len(p)])+p.encode() for p in name.split('.'))+b'\0'+struct.pack('!HH',typ,1)
        return struct.pack('!6H',12345,0x100,1,0,0,0)+q
    def test_preserves_identity_question_and_fixed_answer(self):
        req=self.query(); out,name=fixture.dns_reply(req)
        self.assertEqual(struct.unpack('!6H',out[:12]),(12345,0x8180,1,1,0,0))
        self.assertEqual(out[12:len(req)],req[12:])
        self.assertEqual(out[-4:],bytes([10,253,203,1]))
        self.assertEqual(name,'unique.r12.test')
    def test_external_questions_are_rejected_without_upstream(self):
        with self.assertRaises(ValueError): fixture.dns_reply(self.query('example.com'))
    def test_aaaa_not_silently_answered_as_a(self):
        with self.assertRaises(ValueError): fixture.dns_reply(self.query(typ=28))
    def test_short_compressed_trailing_and_multiquestion_rejected(self):
        req=self.query()
        for bad in [b'',req[:15],req+b'extra',req[:4]+b'\0\2'+req[6:],req[:12]+b'\xc0\x0c\0\1\0\1']:
            with self.subTest(data=bad):
                with self.assertRaises((ValueError,UnicodeError)): fixture.dns_reply(bad)
if __name__=='__main__': unittest.main()
