"""Persistent audit trail survives processes, rotates, and omits secret fields."""
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).parents[1] / 'watchdog/overlay/usr/lib/cpe-watchdog'
sys.path.insert(0, str(SOURCE))


class AuditTests(unittest.TestCase):
    def setUp(self):
        try:
            self.audit = importlib.import_module('audit')
        except ImportError:
            self.audit = None
        self.assertIsNotNone(self.audit, 'Persistent audit module missing')
        parent=Path(os.environ.get('TMPDIR', str(Path.home()/'.paseo/.tmp')))
        parent.mkdir(parents=True, exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)/'events.jsonl'

    def test_reboot_decision_is_fsynced_and_survives_new_process(self):
        with patch('os.fsync', wraps=os.fsync) as sync:
            self.audit.write_event('openwrt_reboot_requested', path=self.path, cycle='fixture')
            self.assertGreater(sync.call_count, 0)
        subprocess.run([sys.executable, str(SOURCE/'audit.py'), '--log-file', str(self.path),
            'service_started', 'source=detector'], check=True, capture_output=True)
        rows=[json.loads(line) for line in self.path.read_text().splitlines()]
        self.assertEqual([r['event'] for r in rows], ['openwrt_reboot_requested','service_started'])
        self.assertTrue(all(r['boot_id'] and r['timestamp'] and r['uptime_s']>=0 for r in rows))
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_rotation_bounds_storage_and_retains_recent_events(self):
        for i in range(15):
            self.audit.write_event('https_probe', path=self.path, max_bytes=600, backups=2, cycle=str(i))
        files=list(self.path.parent.glob('events.jsonl*'))
        self.assertLessEqual(len(files), 4)  # active, two archives, lock
        self.assertEqual(json.loads(self.path.read_text().splitlines()[-1])['cycle'], '14')

    def test_secret_fields_are_rejected(self):
        for key in ('password','token','cookie','clientproof','username'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.audit.write_event('api_request', path=self.path, **{key:'fixture-secret'})
        self.assertFalse(self.path.exists())
