"""Bounded, fsynced JSONL history shared by the detector and recovery processes."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import syslog
import time
import uuid

DEFAULT_PATH = '/etc/cpe-watchdog/events.jsonl'
PROCESS_CYCLE = os.environ.get('CPE_WATCHDOG_DETECTOR_CYCLE') or uuid.uuid4().hex[:12]
FIELDS = {'source', 'cycle', 'instance', 'target', 'index', 'result', 'curl_rc',
          'http_status', 'elapsed_s', 'reason', 'model', 'wait_s', 'phase',
          'attempt', 'action', 'error_type', 'api', 'command', 'version', 'mode',
          'checked', 'skipped', 'targets', 'interval_s'}


def write_event(event, path=DEFAULT_PATH, max_bytes=1048576, backups=4, **fields):
    if set(fields) - FIELDS:
        raise ValueError('Unsupported audit fields; authentication data must never be logged')
    fields.setdefault('cycle', PROCESS_CYCLE)
    record = dict(timestamp=datetime.now(timezone.utc).isoformat(),
        boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
        uptime_s=round(time.monotonic(), 3), pid=os.getpid(), event=event, **fields)
    line = (json.dumps(record, ensure_ascii=True, separators=(',', ':')) + '\n').encode()
    syslog.openlog('cpe-watchdog', syslog.LOG_PID, syslog.LOG_DAEMON)
    syslog.syslog(syslog.LOG_INFO, line.decode().strip())
    path = Path(path)
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with open(str(path) + '.lock', 'a') as lock:
            os.fchmod(lock.fileno(), 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            if path.exists() and path.stat().st_size + len(line) > max_bytes:
                for index in range(backups, 0, -1):
                    previous = path if index == 1 else Path(str(path) + '.' + str(index - 1))
                    if previous.exists():
                        previous.replace(str(path) + '.' + str(index))
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, 'ab') as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(line)
                output.flush()
                os.fsync(output.fileno())
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    except OSError as error:
        # Storage failure must not prevent network recovery. Syslog remains a fallback.
        syslog.syslog(syslog.LOG_ERR, 'event=audit_write_failed errno=' + str(error.errno))
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log-file', default=DEFAULT_PATH)
    parser.add_argument('event')
    parser.add_argument('fields', nargs='*')
    args = parser.parse_args()
    fields = dict(item.split('=', 1) for item in args.fields)
    write_event(args.event, path=args.log_file, **fields)


if __name__ == '__main__':
    main()
