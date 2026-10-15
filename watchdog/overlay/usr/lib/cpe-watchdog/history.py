"""Sanitized, read-only access to retained cpe-watchdog JSONL history."""
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path


DEFAULT_PATH = Path('/etc/cpe-watchdog/events.jsonl')
ARCHIVE_COUNT = 4
MAX_PAGE = 1000000
MAX_PAGE_SIZE = 100
MAX_EXPORT_OFFSET = 1000000
MAX_EXPORT_LIMIT = 500
MAX_EVENT_LENGTH = 64

# Keep this independent of future audit.py additions: a newly added field is not
# exposed until it has been deliberately reviewed for the LuCI history boundary.
SAFE_FIELDS = {
    'timestamp', 'boot_id', 'uptime_s', 'pid', 'event', 'source', 'cycle',
    'instance', 'target', 'index', 'result', 'curl_rc', 'http_status',
    'elapsed_s', 'reason', 'model', 'wait_s', 'phase', 'attempt', 'action',
    'error_type', 'api', 'command', 'version', 'mode', 'checked', 'skipped',
    'targets', 'interval_s',
}
SCALAR_TYPES = (str, int, float, bool)


class InvalidParams(ValueError):
    """An RPC parameter failed the public history contract."""


def _integer(params, name, default, minimum, maximum):
    value = params.get(name, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise InvalidParams(f'{name} must be an integer')
    if value < minimum or value > maximum:
        raise InvalidParams(f'{name} must be between {minimum} and {maximum}')
    return value


def _filters(params):
    date = params.get('date', '')
    if not isinstance(date, str):
        raise InvalidParams('date must be a string')
    if date:
        try:
            parsed = datetime.strptime(date, '%Y-%m-%d')
        except ValueError as error:
            raise InvalidParams('date must use YYYY-MM-DD') from error
        if parsed.strftime('%Y-%m-%d') != date:
            raise InvalidParams('date must use YYYY-MM-DD')

    event = params.get('event', '')
    if not isinstance(event, str):
        raise InvalidParams('event must be a string')
    if len(event) > MAX_EVENT_LENGTH:
        raise InvalidParams(f'event must be at most {MAX_EVENT_LENGTH} characters')
    if event and not all(character.isalnum() or character in '_.:-' for character in event):
        raise InvalidParams('event contains unsupported characters')
    return date, event


def _validate_params(params, allowed):
    if not isinstance(params, dict):
        raise InvalidParams('parameters must be an object')
    unknown = set(params) - allowed
    if unknown:
        raise InvalidParams('unsupported parameter: ' + sorted(unknown)[0])


def _parse_timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def _safe_record(value):
    if not isinstance(value, dict):
        return None
    timestamp = _parse_timestamp(value.get('timestamp'))
    event = value.get('event')
    if timestamp is None or not isinstance(event, str) or not event:
        return None

    record = {}
    for key in SAFE_FIELDS:
        field = value.get(key)
        if isinstance(field, float) and not math.isfinite(field):
            continue
        if isinstance(field, SCALAR_TYPES) or field is None and key in value:
            record[key] = field
        elif key == 'targets' and isinstance(field, list) and all(
                (isinstance(item, SCALAR_TYPES) and
                 (not isinstance(item, float) or math.isfinite(item))) or item is None
                for item in field):
            record[key] = field
    return timestamp, record


def _load(base_path):
    base_path = Path(base_path)
    rows = []
    sequence = 0
    for archive_index in range(ARCHIVE_COUNT + 1):
        suffix = '' if archive_index == 0 else f'.{archive_index}'
        path = Path(str(base_path) + suffix)
        try:
            lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
        except OSError:
            continue
        for line_index, line in enumerate(lines):
            sequence += 1
            try:
                value = json.loads(line)
            except (json.JSONDecodeError, TypeError):
                continue
            sanitized = _safe_record(value)
            if sanitized is not None:
                timestamp, record = sanitized
                rows.append((timestamp, -archive_index, line_index, sequence, record))
    rows.sort(key=lambda row: (row[0], row[1], row[2], -row[3]), reverse=True)
    return [row[4] for row in rows]


def _filtered(params, records):
    date, event = _filters(params)
    if date:
        records = [record for record in records
                   if _parse_timestamp(record['timestamp']).date().isoformat() == date]
    if event:
        records = [record for record in records if event in record['event']]
    return records


def query(params, base_path=DEFAULT_PATH):
    """Return one newest-first page plus retained and filtered bounds."""
    _validate_params(params, {'page', 'page_size', 'date', 'event'})
    page = _integer(params, 'page', 1, 1, MAX_PAGE)
    page_size = _integer(params, 'page_size', 25, 1, MAX_PAGE_SIZE)
    retained = _load(base_path)
    available = len(retained)
    records = _filtered(params, retained)
    total = len(records)
    pages = (total + page_size - 1) // page_size
    start = (page - 1) * page_size
    selected = records[start:start + page_size]
    first = start + 1 if selected else 0
    last = start + len(selected) if selected else 0
    return {
        'records': selected,
        'meta': {
            'available': available,
            'total': total,
            'page': page,
            'page_size': page_size,
            'pages': pages,
            'first': first,
            'last': last,
        },
    }


def export_chunk(params, base_path=DEFAULT_PATH):
    """Return a bounded JSONL chunk from the complete filtered history."""
    _validate_params(params, {'offset', 'limit', 'date', 'event', 'snapshot'})
    offset = _integer(params, 'offset', 0, 0, MAX_EXPORT_OFFSET)
    limit = _integer(params, 'limit', 200, 1, MAX_EXPORT_LIMIT)
    retained = _load(base_path)
    available = len(retained)
    records = _filtered(params, retained)
    total = len(records)
    snapshot = hashlib.sha256(json.dumps(records, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    requested = params.get('snapshot', '')
    if not isinstance(requested, str) or (requested and requested != snapshot):
        raise InvalidParams('日志在导出期间发生变化，请重新导出')
    selected = records[offset:offset + limit]
    data = ''.join(json.dumps(record, ensure_ascii=True, separators=(',', ':')) + '\n'
                   for record in selected)
    next_offset = offset + len(selected)
    if next_offset >= total:
        next_offset = None
    return {
        'data': data,
        'count': len(selected),
        'offset': offset,
        'next_offset': next_offset,
        'available': available,
        'total': total,
        'snapshot': snapshot,
    }
