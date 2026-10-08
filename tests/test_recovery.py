import importlib.util
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

ROOT = Path(__file__).parents[1] / 'watchdog/overlay/usr/lib/cpe-watchdog'
sys.path.insert(0, str(ROOT))
try:
    import recovery
except ImportError:
    recovery = None


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(recovery, 'Recovery component is missing')
        self.events = []
        self.audit = self.enterContext(patch('recovery.write_event', create=True))

    def execute(self, results, cpe_error=False):
        results = iter(results)
        def check(*args):
            self.events.append('https')
            return next(results)
        def restart(*args):
            self.events.append('cpe')
            if cpe_error:
                raise RuntimeError('CPE unreachable')
        return recovery.recover(recovery.Settings(), probe=check, cpe_reboot=restart,
            sleep=lambda n: self.events.append(('wait', n)),
            local_reboot=lambda cmd: self.events.append(('openwrt', cmd)))

    def test_recovery_audit_records_wait_recheck_and_reboot_order(self):
        self.execute([False, False])
        names=[call.args[0] for call in self.audit.call_args_list]
        self.assertEqual(names, ['recovery_started','https_round','cpe_reboot_attempt',
            'cpe_reboot_acknowledged','recovery_wait','https_round','openwrt_reboot_requested'])
        self.assertEqual(self.audit.call_args_list[4].kwargs['wait_s'],120)

    def test_online_never_reboots(self):
        self.assertEqual(self.execute([True]), 'online')
        self.assertEqual(self.events, ['https'])

    def test_cpe_recovery_waits_120_seconds_before_https_recheck(self):
        self.assertEqual(self.execute([False, True]), 'recovered')
        self.assertEqual(self.events, ['https', 'cpe', ('wait', 120), 'https'])

    def test_persistent_outage_reboots_openwrt_after_recheck(self):
        self.assertEqual(self.execute([False, False]), 'rebooting')
        self.assertEqual(self.events, ['https', 'cpe', ('wait', 120), 'https',
            ('openwrt', ['/sbin/reboot'])])

    def test_failed_cpe_api_still_waits_and_rechecks(self):
        self.assertEqual(self.execute([False, False], True), 'rebooting')
        self.assertEqual(self.events[2:4], [('wait', 120), 'https'])

    def test_failed_cpe_api_does_not_override_recovered_https(self):
        self.assertEqual(self.execute([False, True], True), 'recovered')
        self.assertEqual(len(self.events), 4)

    def test_repeated_calls_and_fresh_processes_have_no_once_only_latch(self):
        self.execute([False, False])
        self.execute([False, False])
        self.assertEqual(self.events.count('cpe'), 2)
        self.assertEqual(sum(e == ('openwrt', ['/sbin/reboot']) for e in self.events), 2)

    def test_credentials_missing_prevents_automatic_recovery(self):
        settings = recovery.Settings(password_file='/does/not/exist')
        with self.assertRaises(recovery.ConfigurationError):
            recovery.validate_credentials(settings.password_file)

    def test_rejects_empty_targets_plain_http_and_credential_urls(self):
        for urls in [[], ['http://www.baidu.com'], ['https://user:pass@example.com']]:
            with self.subTest(urls=urls), self.assertRaises(ValueError):
                recovery.Settings(urls=urls)

    def test_invalid_timing_and_nonabsolute_reboot_command_rejected(self):
        for kwargs in [{'timeout': 0}, {'recovery_wait': -1}, {'reboot_command': 'reboot'}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                recovery.Settings(**kwargs)

    def test_uci_exports_list_and_custom_reboot_script_without_shell_evaluation(self):
        config = """package internet-detector
config main 'config'
 option mode '1'
config instance 'internet'
 list urls 'https://www.baidu.com/'
 list urls 'https://www.qq.com/'
 option check_type '2'
 option connection_timeout '12'
"""
        cpe_config = """package cpe-watchdog
config recovery 'main'
 option address 'http://192.168.10.1'
 option username 'admin'
 option password_file '/etc/cpe-watchdog/password'
 option recovery_wait '120'
 option reboot_command '/root/restart.sh --reason outage'
"""
        settings = recovery.settings_from_exports(config, cpe_config)
        self.assertEqual(settings.urls, ['https://www.baidu.com/', 'https://www.qq.com/'])
        self.assertEqual(settings.timeout, 12)
        self.assertEqual(settings.reboot_argv, ['/root/restart.sh', '--reason', 'outage'])


class HttpsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if recovery is None:
            return
        temporary_root = Path(os.environ.get('TMPDIR', str(Path.home() / '.paseo/.tmp')))
        temporary_root.mkdir(parents=True, exist_ok=True)
        cls.tmp = tempfile.TemporaryDirectory(dir=temporary_root)
        cls.cert = str(Path(cls.tmp.name) / 'cert.pem')
        key = str(Path(cls.tmp.name) / 'key.pem')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', key, '-out', cls.cert, '-days', '1', '-subj', '/CN=localhost',
            '-addext', 'subjectAltName=DNS:localhost'], check=True, capture_output=True)
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302 if self.path == '/redirect' else 503)
                if self.path == '/redirect':
                    self.send_header('Location', 'http://127.0.0.1:1/plaintext')
                self.send_header('Content-Length', '11')
                self.end_headers()
                self.wfile.write(b'HTTPS works')
            def log_message(self, *args):
                pass
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.cert, key)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = 'https://localhost:' + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        if recovery is not None:
            cls.server.shutdown()
            cls.server.server_close()
            cls.thread.join()
            cls.tmp.cleanup()

    def setUp(self):
        self.assertIsNotNone(recovery, 'HTTPS implementation is missing')

    def test_probe_audit_covers_every_target_without_query_secrets(self):
        with patch('recovery.write_event', create=True) as audit, patch.dict(os.environ, {'CURL_CA_BUNDLE':self.cert}):
            self.assertTrue(recovery.https_online(['https://127.0.0.1:1/?token=fixture-secret', self.url],2))
        rows=[call.kwargs for call in audit.call_args_list if call.args[0]=='https_probe']
        self.assertEqual(len(rows),2)
        self.assertEqual({row['result'] for row in rows},{'online','offline'})
        self.assertNotIn('fixture-secret',str(rows))
        self.assertTrue(all('elapsed_s' in row and 'curl_rc' in row for row in rows))

    def test_untrusted_tls_is_offline(self):
        with patch.dict(os.environ, {'CURL_CA_BUNDLE': '/etc/ssl/certs/ca-certificates.crt'}):
            self.assertFalse(recovery.https_online([self.url], 2))

    def test_any_verified_https_response_is_online_including_http_error(self):
        with patch.dict(os.environ, {'CURL_CA_BUNDLE': self.cert}):
            self.assertTrue(recovery.https_online(['https://127.0.0.1:1', self.url], 2))

    def test_all_failed_targets_are_offline(self):
        self.assertFalse(recovery.https_online(['https://127.0.0.1:1', 'https://127.0.0.1:2'], 1))

    def test_https_redirect_not_followed_to_http(self):
        with patch.dict(os.environ, {'CURL_CA_BUNDLE': self.cert}):
            self.assertTrue(recovery.https_online([self.url + '/redirect'], 2))


if __name__ == '__main__':
    unittest.main()
