"""LG6851F web API transport. Device credentials and firmware key stay local."""
import base64
import gzip
import json
import secrets
import time
import urllib.error
import urllib.request

from audit import write_event
from cpe import CpeError, HuaweiCpe

PROTOCOL_KEY_FILE = '/etc/cpe-watchdog/fiberhome-rsa.pem'
IV = b'opqrstuvwxyz{|}~'


class FiberhomeCpe:
    def __init__(self, address, timeout=10):
        # Share the strict origin validation and proxy-free cookie transport.
        transport = HuaweiCpe(address, timeout)
        self.address, self.timeout, self.client = transport.address, timeout, transport.client
        self.protocol = None

    def raw(self, path, data=None):
        started = time.monotonic()
        write_event('cpe_api_request', api=path.split('?')[0])
        try:
            request = urllib.request.Request(self.address + path, data=data,
                headers={'Content-Type': 'application/json; charset=utf-8',
                    'X-Requested-With': 'XMLHttpRequest', 'Referer': self.address + '/login.html'})
            with self.client.open(request, timeout=self.timeout) as response:
                body = response.read(131073)
            if len(body) > 131072:
                raise CpeError('CPE response exceeds size limit')
            if body[:2] == b'\x1f\x8b':
                body = gzip.decompress(body)
            if len(body) > 131072:
                raise CpeError('CPE response exceeds size limit')
            write_event('cpe_api_response', api=path.split('?')[0], result='ok',
                elapsed_s=round(time.monotonic()-started, 3))
            return body
        except (OSError, urllib.error.URLError, EOFError) as error:
            write_event('cpe_api_response', api=path.split('?')[0], result='failed',
                error_type=type(error).__name__, elapsed_s=round(time.monotonic()-started, 3),
                http_status=getattr(error, 'code', None))
            raise CpeError('LG6851F API transport failed') from None

    def initialize(self):
        if self.protocol is not None:
            return
        try:
            from cryptography.hazmat.primitives.serialization import load_pem_private_key
            from cryptography.hazmat.primitives.asymmetric.padding import PKCS1v15
            from cpe import read_private_file
            key = load_pem_private_key(read_private_file(PROTOCOL_KEY_FILE, 8192), None)
            config = json.loads(self.raw('/fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt'))['data']
            if not isinstance(config, str) or config[5:6] != '1':
                raise ValueError
            protocol = key.decrypt(base64.b64decode(config[6:], validate=True), PKCS1v15()).decode('ascii')
            if len(protocol) != 5 or not protocol.isascii():
                raise ValueError
            self.protocol = protocol
        except (ImportError, OSError, ValueError, KeyError, TypeError):
            raise CpeError('LG6851F encrypted API bootstrap failed; check local firmware key and dependency') from None

    def session_key(self, session):
        if not isinstance(session, str) or len(session) != 32 or not session.isascii():
            raise CpeError('Invalid LG6851F session')
        shift, special = ord(session[1]) % 3 - 1, [5, 7, 10, 11, 13]
        result = []
        for i in range(16):
            if i in special:
                result.append(chr(ord(self.protocol[special.index(i)]) + shift))
            elif len(session) > i * 4 + 2:
                result.append(chr(ord(session[len(session) - 2 - i * 4]) - 1))
            else:
                result.append(chr(ord(session[i * 4 - 31]) + 1))
        return ''.join(result).encode('ascii')

    @staticmethod
    def crypt(data, key, encrypt):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.padding import PKCS7
        cipher = Cipher(algorithms.AES(key), modes.CBC(IV))
        if encrypt:
            pad = PKCS7(128).padder()
            data = pad.update(data) + pad.finalize()
            worker = cipher.encryptor()
            return worker.update(data) + worker.finalize()
        worker = cipher.decryptor()
        plain = worker.update(data) + worker.finalize()
        pad = PKCS7(128).unpadder()
        return pad.update(plain) + pad.finalize()

    def request(self, action, fields=None, nocheck=False):
        self.initialize()
        try:
            session = json.loads(self.raw('/fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid'))['sessionid']
            key = self.session_key(session)
            payload = json.dumps(dict(dataObj=fields, ajaxmethod=action, sessionid=session),
                ensure_ascii=False, separators=(',', ':')).encode()
            encoded = secrets.token_hex(3).encode() + self.crypt(payload, key, True).hex().encode()
            signing = action in ('DO_WEB_LOGIN', 'DO_WEB_LOGOUT')
            path = '/fh_api/sign/' + action if signing else '/fh_api/tmp/' + ('FHNCAPIS' if nocheck else 'FHAPIS')
            body = self.raw(path, encoded)
            if action == 'DO_WEB_LOGOUT' and body.strip() == b'success':
                return {'success': True}
            if not signing:
                body = self.crypt(bytes.fromhex(body.decode()[6:]), key, False)
            result = json.loads(body)
            if not isinstance(result, dict):
                raise ValueError
            return result
        except (ValueError, TypeError, KeyError, UnicodeError):
            raise CpeError('Invalid LG6851F API response') from None

    def detect_model(self):
        model = self.request('get_device_info', nocheck=True).get('model_name')
        if not isinstance(model, str) or not model or len(model) > 64:
            raise CpeError('LG6851F model identification failed')
        return model.strip()

    def login(self, username, password):
        result = self.request('DO_WEB_LOGIN', {'username': username, 'password': password})
        if type(result.get('result')) is not int or result['result'] != 0:
            raise CpeError('LG6851F login rejected')

    def reboot(self):
        for command in ('RECORD_MESSAGE_WEB', 'REBOOT_WEB'):
            result = self.request('do_cmd_web', {'key': command})
            if result.get('success') not in (True, 'true'):
                raise CpeError('LG6851F did not acknowledge ' + command)

    def logout(self):
        result = self.request('DO_WEB_LOGOUT')
        if result.get('success') not in (True, 'true'):
            raise CpeError('LG6851F logout rejected')
