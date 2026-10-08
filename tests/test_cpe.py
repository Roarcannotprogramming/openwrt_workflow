import os
import hashlib
import hmac
import http.server
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).parents[1] / 'watchdog/overlay/usr/lib/cpe-watchdog'))
try:
    import cpe
except ImportError:
    cpe = None


class CpeApiTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(cpe, 'CPE API component is missing')
        self.audit = self.enterContext(patch('cpe.write_event',create=True))
        self.model = 'H155-380'
        self.events = []
        self.bad_signature = False
        self.fail_control = False
        temporary_root = Path(os.environ.get('TMPDIR', str(Path.home() / '.paseo/.tmp')))
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=temporary_root)
        self.password_file = Path(self.tmp.name) / 'password'
        self.password_file.write_text('fixture-password\n')
        self.password_file.chmod(0o600)
        test = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def reply(self, body, token=None, cookie=False):
                self.send_response(200)
                if token:
                    self.send_header('__RequestVerificationToken', token)
                if cookie:
                    self.send_header('Set-Cookie', 'SessionID=fixture-session; path=/')
                self.end_headers()
                self.wfile.write(body.encode())
            def do_GET(self):
                test.events.append(('GET', self.path))
                if self.path == '/api/device/basic_information':
                    self.reply('<response><devicename>'+test.model+'</devicename></response>')
                elif self.path == '/':
                    self.reply('<html/>', cookie=True)
                elif self.path == '/api/webserver/SesTokInfo':
                    self.reply('<response><TokInfo>initial-token</TokInfo></response>')
                elif self.path == '/api/voice/voicebusy':
                    self.reply('<response><voicebusy>Idle</voicebusy></response>')
                else:
                    self.reply('<error><code>100002</code></error>')
            def do_POST(self):
                root = ET.fromstring(self.rfile.read(int(self.headers['Content-Length'])))
                fields = {child.tag: child.text for child in root}
                test.events.append(('POST', self.path, fields))
                test.assertEqual(self.headers.get('Cookie'), 'SessionID=fixture-session')
                if self.path == '/api/user/challenge_login':
                    test.assertEqual(fields['username'], 'admin')
                    test.assertEqual(fields['mode'], '1')
                    test.assertEqual(self.headers.get('__RequestVerificationToken'), 'initial-token')
                    test.nonce = fields['firstnonce']
                    self.reply('<response><salt>73616c74</salt><iterations>100</iterations>'
                        '<servernonce>server-nonce</servernonce></response>', 'challenge-token')
                elif self.path == '/api/user/authentication_login':
                    test.assertEqual(self.headers.get('__RequestVerificationToken'), 'challenge-token')
                    salted = hashlib.pbkdf2_hmac('sha256', b'fixture-password', b'salt', 100)
                    key = hmac.new(b'Client Key', salted, hashlib.sha256).digest()
                    msg = (test.nonce+',server-nonce,server-nonce').encode()
                    sign = hmac.new(msg, hashlib.sha256(key).digest(), hashlib.sha256).digest()
                    test.assertEqual(fields['clientproof'], bytes(a^b for a,b in zip(key,sign)).hex())
                    test.assertEqual(fields['finalnonce'], 'server-nonce')
                    serverkey = hmac.new(b'Server Key', salted, hashlib.sha256).digest()
                    signature = hmac.new(msg, serverkey, hashlib.sha256).hexdigest()
                    if test.bad_signature:
                        signature = 'wrong'
                    self.send_response(200)
                    self.send_header('__RequestVerificationTokenone', 'auth-token')
                    self.end_headers()
                    self.wfile.write(('<response><serversignature>'+signature+'</serversignature></response>').encode())
                elif self.path == '/api/device/control':
                    test.assertEqual(self.headers.get('__RequestVerificationToken'), 'auth-token')
                    test.assertEqual(fields, {'Control': '1'})
                    self.reply('<error><code>100003</code></error>' if test.fail_control else '<response>OK</response>')
                elif self.path == '/api/user/logout':
                    self.reply('<response>OK</response>')
                else:
                    test.fail('unexpected POST ' + self.path)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = 'http://127.0.0.1:' + str(self.server.server_port)

    def tearDown(self):
        if hasattr(self, 'server'):
            self.server.shutdown()
            self.server.server_close()
            self.thread.join()
            self.tmp.cleanup()

    def test_model_dispatched_authenticated_reboot_uses_rotated_token(self):
        self.assertEqual(cpe.reboot_cpe(self.url, 'admin', str(self.password_file)), 'H155-380')
        controls = [e for e in self.events if e[:2] == ('POST', '/api/device/control')]
        self.assertEqual(len(controls), 1)

    def test_unknown_model_never_authenticates_or_posts_control(self):
        self.model = 'unknown-cpe'
        with self.assertRaises(cpe.UnsupportedModel):
            cpe.reboot_cpe(self.url, 'admin', str(self.password_file))
        self.assertEqual(self.events, [('GET', '/api/device/basic_information')])

    def test_api_audit_identifies_model_and_paths_without_credentials(self):
        cpe.reboot_cpe(self.url, 'admin', str(self.password_file))
        rows=self.audit.call_args_list
        self.assertTrue(any(call.args[0]=='cpe_identified' and call.kwargs['model']=='H155-380' for call in rows))
        self.assertTrue(any(call.args[0]=='cpe_api_request' and call.kwargs['api']=='/api/device/control' for call in rows))
        self.assertNotIn('fixture-password',str(rows))
        self.assertNotIn('clientproof',str(rows))

    def test_auth_only_does_not_reboot(self):
        client = cpe.HuaweiCpe(self.url)
        client.login('admin', 'fixture-password')
        client.logout()
        self.assertFalse(any(e[:2] == ('POST', '/api/device/control') for e in self.events))

    def test_bad_server_proof_never_posts_control(self):
        self.bad_signature = True
        with self.assertRaises(cpe.CpeError):
            cpe.reboot_cpe(self.url, 'admin', str(self.password_file))
        self.assertFalse(any(e[:2] == ('POST', '/api/device/control') for e in self.events))

    def test_reboot_api_error_is_not_reported_as_success(self):
        self.fail_control = True
        with self.assertRaises(cpe.CpeError):
            cpe.reboot_cpe(self.url, 'admin', str(self.password_file))


if __name__ == '__main__':
    unittest.main()
