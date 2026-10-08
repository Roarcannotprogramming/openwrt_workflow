"""Model-dispatched CPE APIs; only verified models may receive reboot requests."""
import gzip
import hashlib
import hmac
import http.cookiejar
import os
from pathlib import Path
import secrets
import stat
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

from audit import write_event


class CpeError(RuntimeError):
    pass


class UnsupportedModel(CpeError):
    pass


def read_password(path):
    try:
        with open(path, 'r') as file:
            info = os.fstat(file.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise CpeError('Credential file must be owned by the service user with mode 0600')
            password = file.read(4096).rstrip('\r\n')
    except OSError:
        raise CpeError('Credential file is missing or unreadable') from None
    if not password:
        raise CpeError('Credential file is empty')
    return password


class HuaweiCpe:
    def __init__(self, address, timeout=10):
        url = urllib.parse.urlsplit(address)
        if (url.scheme not in ('http', 'https') or not url.hostname or url.username
                or url.password or url.query or url.fragment or url.path not in ('', '/')):
            raise CpeError('CPE address must be an HTTP(S) origin without credentials')
        self.address = address.rstrip('/')
        self.timeout = timeout
        self.token = ''
        self.client = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(self, path, fields=None, xml=True):
        write_event('cpe_api_request', api=path)
        headers = {'X-Requested-With': 'XMLHttpRequest', '_ResponseSource': 'Broswer'}
        data = None
        if fields is not None:
            root = ET.Element('request')
            for key, value in fields.items():
                ET.SubElement(root, key).text = str(value)
            data = ET.tostring(root, encoding='utf-8', xml_declaration=True)
            headers.update({'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                            '__RequestVerificationToken': self.token})
        try:
            request = urllib.request.Request(self.address + path, data=data, headers=headers)
            with self.client.open(request, timeout=self.timeout) as response:
                body = response.read(131073)
                if len(body) > 131072:
                    raise CpeError('CPE response exceeds size limit')
                if body[:2] == b'\x1f\x8b':
                    body = gzip.decompress(body)
                for key in ('__RequestVerificationTokenone', '__RequestVerificationToken'):
                    if response.headers.get(key):
                        self.token = response.headers[key].split('#')[0]
                        break
            if not xml:
                write_event('cpe_api_response', api=path, result='ok')
                return body
            root = ET.fromstring(body)
        except (OSError, urllib.error.URLError, ET.ParseError, EOFError) as error:
            write_event('cpe_api_response', api=path, result='failed', error_type=type(error).__name__)
            raise CpeError('CPE request failed: ' + path) from None
        if root.tag == 'error':
            code=root.findtext('code','unknown')
            code=code if code.isdigit() else 'unknown'
            write_event('cpe_api_response', api=path, result='failed', reason='api_error_'+code)
            raise CpeError('CPE API error at ' + path + ': ' + code)
        if root.tag != 'response':
            write_event('cpe_api_response', api=path, result='failed', reason='unexpected_response')
            raise CpeError('Unexpected CPE API response: ' + path)
        write_event('cpe_api_response', api=path, result='ok')
        return root

    def login(self, username, password):
        self.request('/', xml=False)
        self.token = self.request('/api/webserver/SesTokInfo').findtext('TokInfo', '')
        if not self.token:
            raise CpeError('CPE did not return a login token')
        nonce = secrets.token_hex(32)
        challenge = self.request('/api/user/challenge_login',
            {'username': username, 'firstnonce': nonce, 'mode': 1})
        try:
            salt = bytes.fromhex(challenge.findtext('salt'))
            iterations = int(challenge.findtext('iterations'))
            servernonce = challenge.findtext('servernonce')
            if not 1 <= iterations <= 1000000 or not servernonce:
                raise ValueError
        except (ValueError, TypeError):
            raise CpeError('Invalid CPE login challenge') from None
        message = (nonce + ',' + servernonce + ',' + servernonce).encode()
        salted = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, iterations)
        # Huawei's SCRAM variant reverses the usual HMAC message/key order.
        key = hmac.new(b'Client Key', salted, hashlib.sha256).digest()
        signature = hmac.new(message, hashlib.sha256(key).digest(), hashlib.sha256).digest()
        proof = bytes(a ^ b for a, b in zip(key, signature)).hex()
        fields = {'clientproof': proof, 'finalnonce': servernonce}
        if challenge.findtext('newType') == '1':
            try:
                count = int(challenge.findtext('newIterations'))
                if not 1 <= count <= 1000000:
                    raise ValueError
                new_salted = hashlib.pbkdf2_hmac('sha256', password.encode(),
                    bytes.fromhex(challenge.findtext('newSalt')), count)
            except (ValueError, TypeError):
                raise CpeError('Invalid CPE password migration challenge') from None
            stored = hashlib.sha256(hmac.new(b'Client Key', new_salted, hashlib.sha256).digest()).hexdigest()
            server = hmac.new(b'Server Key', new_salted, hashlib.sha256).hexdigest()
            fields.update(newStoredKey=stored, newServerKey=server,
                hashOldNewPwd=hashlib.sha256((stored + server + proof).encode()).hexdigest())
        auth = self.request('/api/user/authentication_login', fields)
        serverkey = hmac.new(b'Server Key', salted, hashlib.sha256).digest()
        expected = hmac.new(message, serverkey, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(auth.findtext('serversignature', ''), expected):
            raise CpeError('CPE server authentication proof is invalid')

    def reboot(self):
        if self.request('/api/device/control', {'Control': 1}).text != 'OK':
            raise CpeError('CPE did not acknowledge reboot')

    def logout(self):
        self.request('/api/user/logout', {'Logout': 1})


def detect_model(address):
    model = HuaweiCpe(address).request('/api/device/basic_information').findtext('devicename')
    if not model:
        raise CpeError('CPE model identification failed')
    model=model.strip()
    write_event('cpe_identified', model=model)
    return model


MODEL_HANDLERS = {'H155-380': HuaweiCpe}


def reboot_cpe(address, username, password_file):
    model = detect_model(address)
    if model not in MODEL_HANDLERS:
        raise UnsupportedModel('Unsupported CPE model: ' + model)
    client = MODEL_HANDLERS[model](address)
    client.login(username, read_password(password_file))
    try:
        client.reboot()
    except CpeError:
        try:
            client.logout()
        except CpeError:
            pass
        raise
    # A successful reboot destroys the session; do not wait for a logout timeout.
    return model
