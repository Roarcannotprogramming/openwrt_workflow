"""Exercise the shipped first-boot script with a sandboxed filesystem/UCI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).parents[1] / 'watchdog/overlay'


class ProvisioningTests(unittest.TestCase):
    def test_first_boot_configures_detector_and_upgrade_preserves_edits(self):
        temp_root = Path(os.environ.get('TMPDIR', str(Path.home() / '.paseo/.tmp')))
        temp_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temp_root) as directory:
            sandbox = Path(directory)
            (sandbox / 'etc/config').mkdir(parents=True)
            tools = sandbox / 'bin'
            tools.mkdir()
            state = sandbox / 'uci.json'
            state.write_text('{}')
            uci = tools / 'uci'
            uci.write_text('#!' + sys.executable + '\n' + '''import json,sys
from pathlib import Path
path=Path(sys.argv[0]).parents[1]/'uci.json'
state=json.loads(path.read_text())
args=[arg for arg in sys.argv[1:] if arg!='-q']
if args[0]=='get':
    if args[1] not in state: raise SystemExit(1)
    print(state[args[1]])
elif args[0]=='set':
    key,value=args[1].split('=',1)
    state[key]=value
    path.write_text(json.dumps(state))
elif args[0]!='commit':
    raise SystemExit(2)
''')
            uci.chmod(0o755)
            init = tools / 'detector-init'
            init.write_text('#!/bin/sh\n[ "$1" = enable ]\n')
            init.chmod(0o755)
            script = (ROOT / 'etc/uci-defaults/95-cpe-watchdog').read_text()
            script = script.replace('/usr/share/cpe-watchdog', str(ROOT / 'usr/share/cpe-watchdog'))
            script = script.replace('/etc/init.d/internet-detector', str(init))
            script = script.replace('/etc/', str(sandbox / 'etc') + '/')
            env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'])
            subprocess.run(['/bin/sh', '-ec', script], env=env, check=True)
            self.assertEqual(json.loads(state.read_text())['cpe-watchdog.main.initialized'], '1')
            config = sandbox / 'etc/config/internet-detector'
            callback = sandbox / 'etc/internet-detector/down-script.internet'
            self.assertEqual(config.read_text(), (ROOT / 'usr/share/cpe-watchdog/internet-detector.conf').read_text())
            self.assertEqual(callback.read_text(), (ROOT / 'usr/share/cpe-watchdog/down-script.internet').read_text())
            config.write_text('user configured HTTPS list\n')
            callback.write_text('user callback\n')
            subprocess.run(['/bin/sh', '-ec', script], env=env, check=True)
            self.assertEqual(config.read_text(), 'user configured HTTPS list\n')
            self.assertEqual(callback.read_text(), 'user callback\n')
            self.assertFalse((sandbox / 'etc/cpe-watchdog/password').exists())
