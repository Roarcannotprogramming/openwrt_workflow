import base64
import http.server
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'watchdog/overlay/usr/lib/cpe-watchdog'))
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7
import cpe


def crypt(data, key, encrypt):
    cipher = Cipher(algorithms.AES(key.encode()), modes.CBC(b'opqrstuvwxyz{|}~'))
    if encrypt:
        pad = PKCS7(128).padder()
        data = pad.update(data) + pad.finalize()
        worker = cipher.encryptor()
        return worker.update(data) + worker.finalize()
    worker = cipher.decryptor()
    plain = worker.update(data) + worker.finalize()
    pad = PKCS7(128).unpadder()
    return pad.update(plain) + pad.finalize()


class FiberhomeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = self.enterContext(tempfile.TemporaryDirectory())
        self.password = Path(self.tmp) / 'password'
        self.password.write_text('fixture-password\n')
        self.password.chmod(0o600)
        self.private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.keyfile = Path(self.tmp) / 'protocol.pem'
        self.keyfile.write_bytes(self.private.private_bytes(serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.keyfile.chmod(0o600)
        self.enterContext(patch('fiberhome.PROTOCOL_KEY_FILE', str(self.keyfile)))
        self.audit = self.enterContext(patch('fiberhome.write_event'))
        self.enterContext(patch('cpe.write_event'))
        self.events = []
        self.login_result = 0
        self.model = 'LG6851F'
        self.ack = {'success': 'true'}
        test = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def reply(self, body):
                self.send_response(200)
                self.send_header('Set-Cookie', 'fixture=yes; Path=/')
                self.end_headers()
                self.wfile.write(body)
            def do_GET(self):
                if self.path == '/api/device/basic_information':
                    self.send_error(404)
                elif 'ajaxmethod=is_encrypt' in self.path:
                    encrypted = test.private.public_key().encrypt(b'mTmmi', padding.PKCS1v15())
                    self.reply(json.dumps({'data': 'abcde1' + base64.b64encode(encrypted).decode()}).encode())
                elif 'ajaxmethod=get_refresh_sessionid' in self.path:
                    self.reply(json.dumps({'sessionid': '0123456789abcdefghijklmnopqrstuv'}).encode())
                else:
                    self.send_error(404)
            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length'])).decode()
                session = '0123456789abcdefghijklmnopqrstuv'
                shift = ord(session[1]) % 3 - 1
                key = ''.join(chr(ord('mTmmi'[[5,7,10,11,13].index(i)])+shift)
                    if i in [5,7,10,11,13] else chr(ord(session[len(session)-2-i*4])-1)
                    if len(session)>i*4+2 else chr(ord(session[i*4-31])+1) for i in range(16))
                payload = json.loads(crypt(bytes.fromhex(body[6:]), key, False))
                test.assertEqual(payload['sessionid'], session)
                action = payload['ajaxmethod']
                test.events.append(action)
                test.assertEqual(self.headers.get('Cookie'), 'fixture=yes')
                if action == 'get_device_info':
                    result = {'model_name': test.model}
                elif action == 'DO_WEB_LOGIN':
                    test.assertEqual(payload['dataObj'], {'username': 'admin', 'password': 'fixture-password'})
                    result = {'result': test.login_result}
                elif action == 'DO_WEB_LOGOUT':
                    self.reply(b'success\n')
                    return
                elif action == 'do_cmd_web':
                    test.assertIn(payload['dataObj']['key'], ['RECORD_MESSAGE_WEB', 'REBOOT_WEB'])
                    result = test.ack
                else:
                    test.fail('Unexpected method')
                encoded = json.dumps(result).encode()
                if '/sign/' not in self.path:
                    encoded = ('abc123' + crypt(encoded, key, True).hex()).encode()
                self.reply(encoded)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.address = 'http://127.0.0.1:' + str(self.server.server_port)

    def test_detect_authenticate_reboot_with_encrypted_transport(self):
        self.assertEqual(cpe.reboot_cpe(self.address, 'admin', str(self.password)), 'LG6851F')
        self.assertEqual(self.events, ['get_device_info', 'DO_WEB_LOGIN', 'do_cmd_web', 'do_cmd_web'])
        self.assertNotIn('fixture-password', str(self.audit.call_args_list))

    def test_authenticate_never_reboots_and_logs_out(self):
        self.assertEqual(cpe.authenticate_cpe(self.address, 'admin', str(self.password)), 'LG6851F')
        self.assertEqual(self.events, ['get_device_info', 'DO_WEB_LOGIN', 'DO_WEB_LOGOUT'])

    def test_bad_login_never_reboots(self):
        self.login_result = 1
        with self.assertRaises(cpe.CpeError):
            cpe.reboot_cpe(self.address, 'admin', str(self.password))
        self.assertNotIn('do_cmd_web', self.events)

    def test_unknown_model_never_logs_in(self):
        self.model = 'unknown'
        with self.assertRaises(cpe.UnsupportedModel):
            cpe.reboot_cpe(self.address, 'admin', str(self.password))
        self.assertEqual(self.events, ['get_device_info'])

    def test_public_firmware_key_prevents_login_and_control(self):
        self.keyfile.chmod(0o644)
        with self.assertRaises(cpe.CpeError):
            cpe.reboot_cpe(self.address, 'admin', str(self.password))
        self.assertEqual(self.events, [])

    def test_public_password_file_prevents_login_and_control(self):
        self.password.chmod(0o644)
        with self.assertRaises(cpe.CpeError):
            cpe.reboot_cpe(self.address, 'admin', str(self.password))
        self.assertEqual(self.events, ['get_device_info'])

    def test_negative_reboot_ack_fails_and_logs_out(self):
        self.ack = {'result': 'failed'}
        with self.assertRaises(cpe.CpeError):
            cpe.reboot_cpe(self.address, 'admin', str(self.password))
        self.assertEqual(self.events[-1], 'DO_WEB_LOGOUT')
