#!/usr/bin/python3
"""Internet Detector down-script: CPE first, HTTPS recheck, then OpenWrt."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import fcntl
import logging
import logging.handlers
import os
from pathlib import Path
import shlex
import subprocess
import time
from urllib.parse import urlsplit

from audit import write_event
from cpe import CpeError, HuaweiCpe, detect_model, read_password, reboot_cpe

LOG = logging.getLogger('cpe-watchdog')


class ConfigurationError(ValueError):
    pass


@dataclass
class Settings:
    urls: list = field(default_factory=lambda: ['https://www.baidu.com/', 'https://www.qq.com/', 'https://www.bing.com/'])
    timeout: int = 15
    cpe_address: str = 'http://192.168.10.1'
    username: str = 'admin'
    password_file: str = '/etc/cpe-watchdog/password'
    recovery_wait: int = 120
    reboot_command: str = '/sbin/reboot'

    def __post_init__(self):
        if not self.urls or len(self.urls) > 16:
            raise ConfigurationError('Configure between 1 and 16 HTTPS URLs')
        for url in self.urls:
            parsed = urlsplit(url)
            if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
                raise ConfigurationError('Probe targets must be HTTPS URLs without credentials')
        if self.timeout < 1 or self.timeout > 60 or self.recovery_wait < 0:
            raise ConfigurationError('Invalid probe timeout or recovery wait')
        self.reboot_argv = shlex.split(self.reboot_command)
        if not self.reboot_argv or not self.reboot_argv[0].startswith('/'):
            raise ConfigurationError('Local reboot command must use an absolute executable/script path')
        HuaweiCpe(self.cpe_address)


def parse_export(text):
    sections = {}
    current = None
    for line in text.splitlines():
        tokens = shlex.split(line, comments=True)
        if not tokens:
            continue
        if tokens[0] == 'config' and len(tokens) == 3:
            current = sections.setdefault(tokens[2], {})
        elif tokens[0] in ('option', 'list') and len(tokens) == 3 and current is not None:
            if tokens[0] == 'list':
                current.setdefault(tokens[1], []).append(tokens[2])
            else:
                current[tokens[1]] = tokens[2]
    return sections


def settings_from_exports(detector_text, cpe_text, instance='internet'):
    detector = parse_export(detector_text).get(instance, {})
    config = parse_export(cpe_text).get('main', {})
    if detector.get('check_type') != '2':
        raise ConfigurationError('Internet Detector instance must use URL test (check_type=2)')
    return Settings(urls=detector.get('urls', []), timeout=int(detector.get('connection_timeout', '15')),
        cpe_address=config.get('address', 'http://192.168.10.1'),
        username=config.get('username', 'admin'),
        password_file=config.get('password_file', '/etc/cpe-watchdog/password'),
        recovery_wait=int(config.get('recovery_wait', '120')),
        reboot_command=config.get('reboot_command', '/sbin/reboot'))


def load_settings(instance):
    def export(name):
        return subprocess.run(['/sbin/uci', '-q', 'export', name], check=True,
            capture_output=True, text=True, timeout=5).stdout
    return settings_from_exports(export('internet-detector'), export('cpe-watchdog'), instance)


def validate_credentials(path):
    try:
        read_password(path)
    except CpeError as error:
        raise ConfigurationError(str(error)) from None


def https_online(urls, timeout):
    def probe(url):
        started = time.monotonic()
        curl_rc, http_status, reason = None, None, None
        try:
            result = subprocess.run(['/usr/bin/curl', '--silent', '--show-error',
                '--proto', '=https', '--noproxy', '*', '--connect-timeout', str(min(5, timeout)),
                '--max-time', str(timeout), '--output', '/dev/null', '--write-out', '%{http_code}',
                '--', url], capture_output=True, text=True, timeout=timeout + 2)
            # No --fail: an HTTP error still proves the verified HTTPS transport works.
            # No --location: redirects cannot turn the check into plaintext HTTP.
            curl_rc, http_status = result.returncode, int(result.stdout.strip())
            online = curl_rc == 0 and 200 <= http_status <= 599
        except (OSError, subprocess.TimeoutExpired, ValueError) as error:
            online, reason = False, type(error).__name__
        write_event('https_probe', source='recovery', target=urlsplit(url).hostname,
            result='online' if online else 'offline', curl_rc=curl_rc, http_status=http_status,
            elapsed_s=round(time.monotonic()-started,3), reason=reason)
        return online
    with ThreadPoolExecutor(max_workers=min(len(urls), 16)) as pool:
        return any(pool.map(probe, urls))


def local_reboot(command):
    subprocess.run(command, check=True, timeout=15)


def recover(settings, probe=https_online, cpe_reboot=reboot_cpe, sleep=time.sleep,
            local_reboot=local_reboot):
    write_event('recovery_started', source='recovery', targets=len(settings.urls))
    online = probe(settings.urls, settings.timeout)
    write_event('https_round', phase='before_cpe', result='online' if online else 'offline')
    if online:
        LOG.info('HTTPS reachable; no recovery needed')
        return 'online'
    LOG.warning('All HTTPS targets unreachable; attempting CPE recovery')
    write_event('cpe_reboot_attempt', source='recovery')
    try:
        model = cpe_reboot(settings.cpe_address, settings.username, settings.password_file)
        LOG.warning('Reboot acknowledged by CPE model %s', model)
        write_event('cpe_reboot_acknowledged', model=model)
    except Exception as error:
        LOG.error('CPE recovery failed (%s); continuing HTTPS-based fallback', type(error).__name__)
        write_event('cpe_reboot_failed', error_type=type(error).__name__,
            reason=str(error) if isinstance(error,CpeError) else 'CPE operation failed')
    LOG.warning('Waiting %s seconds before HTTPS recheck', settings.recovery_wait)
    write_event('recovery_wait', wait_s=settings.recovery_wait)
    sleep(settings.recovery_wait)
    online = probe(settings.urls, settings.timeout)
    write_event('https_round', phase='after_cpe', result='online' if online else 'offline')
    if online:
        LOG.info('HTTPS recovered; OpenWrt reboot unnecessary')
        return 'recovered'
    LOG.error('HTTPS still unreachable; rebooting OpenWrt')
    write_event('openwrt_reboot_requested', command=settings.reboot_argv[0], reason='all_https_targets_failed')
    local_reboot(settings.reboot_argv)
    return 'rebooting'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['recover', 'check', 'detect', 'authenticate'])
    parser.add_argument('--instance', default='internet')
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(name)s: %(message)s')
    if Path('/dev/log').exists():
        LOG.addHandler(logging.handlers.SysLogHandler(address='/dev/log'))
    write_event('workflow_invoked', action=args.action, instance=args.instance)
    try:
        settings = load_settings(args.instance)
        if args.action == 'check':
            online = https_online(settings.urls, settings.timeout)
            write_event('https_round', phase='manual_check', result='online' if online else 'offline')
            print('online' if online else 'offline')
            return 0 if online else 1
        if args.action == 'detect':
            model=detect_model(settings.cpe_address)
            write_event('cpe_identified', model=model)
            print(model)
            return 0
        validate_credentials(settings.password_file)
        if args.action == 'authenticate':
            if detect_model(settings.cpe_address) != 'H155-380':
                raise CpeError('Unsupported CPE model')
            client = HuaweiCpe(settings.cpe_address)
            client.login(settings.username, read_password(settings.password_file))
            client.logout()
            write_event('cpe_authentication_verified')
            print('Authentication verified; no reboot requested')
            return 0
        with open('/var/run/cpe-watchdog.lock', 'a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                write_event('recovery_skipped', reason='lock_busy')
                LOG.info('Recovery already running; skipping overlapping callback')
                return 0
            uptime = float(Path('/proc/uptime').read_text().split()[0])
            if uptime < 300:
                write_event('boot_grace_wait', wait_s=round(300-uptime,3))
                time.sleep(300 - uptime)
            recover(settings)
        return 0
    except (CpeError, ConfigurationError, ValueError, OSError, subprocess.SubprocessError) as error:
        write_event('workflow_failed', error_type=type(error).__name__,
            reason=str(error) if isinstance(error,(CpeError,ConfigurationError)) else 'operation failed')
        LOG.error('Watchdog stopped: %s', error)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
