"""Read-only retained-history RPC behavior and secret-field containment."""
import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).parents[1] / 'watchdog/overlay/usr/lib/cpe-watchdog'
RPC = Path(__file__).parents[1] / 'watchdog/overlay/usr/libexec/rpcd/luci.cpe-watchdog'
sys.path.insert(0, str(SOURCE))


class HistoryTests(unittest.TestCase):
    def setUp(self):
        try:
            self.history = importlib.import_module('history')
        except ImportError:
            self.history = None
        self.assertIsNotNone(self.history, 'Retained-history module missing')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'events.jsonl'

    def write_rows(self, suffix, rows):
        target = Path(str(self.path) + suffix)
        target.write_text('\n'.join(
            row if isinstance(row, str) else json.dumps(row)
            for row in rows
        ) + '\n')

    def fixture_history(self):
        self.write_rows('.4', [
            {'timestamp': '2026-10-12T23:00:00+00:00', 'event': 'oldest',
             'source': 'detector', 'password': 'archive-secret'},
        ])
        self.write_rows('.2', [
            {'timestamp': '2026-10-13T09:00:00+00:00', 'event': 'probe',
             'result': 'failed', 'cookie': 'archive-cookie'},
        ])
        self.write_rows('.1', [
            {'timestamp': '2026-10-14T10:00:00+00:00', 'event': 'recover',
             'action': 'restart', 'token': 'archive-token'},
            '{malformed json',
            ['not', 'an', 'object'],
            {'timestamp': 'invalid', 'event': 'bad-time'},
            {'timestamp': '2026-10-14T11:00:00+00:00'},
        ])
        self.write_rows('', [
            {'timestamp': '2026-10-15T01:00:00+00:00', 'event': 'probe',
             'result': 'ok', 'username': 'router-admin',
             'nested_unknown': {'access_token': 'nested-secret'}},
            {'timestamp': '2026-10-15T02:00:00+00:00', 'event': 'newest',
             'model': 'fixture', 'elapsed_s': float('nan'),
             'cookies': ['session-secret']},
        ])

    def test_reads_current_and_every_existing_archive_newest_first(self):
        self.fixture_history()

        response = self.history.query({'page': 1, 'page_size': 10}, base_path=self.path)

        self.assertEqual(
            [row['event'] for row in response['records']],
            ['newest', 'probe', 'recover', 'probe', 'oldest'],
        )
        self.assertEqual(response['meta'], {
            'available': 5, 'total': 5, 'page': 1, 'page_size': 10,
            'pages': 1, 'first': 1, 'last': 5,
        })

    def test_filters_by_utc_date_and_event_before_paging(self):
        self.fixture_history()

        response = self.history.query({
            'page': 1, 'page_size': 1, 'date': '2026-10-15', 'event': 'probe',
        }, base_path=self.path)

        self.assertEqual([row['result'] for row in response['records']], ['ok'])
        self.assertEqual(response['meta']['available'], 5)
        self.assertEqual(response['meta']['total'], 1)
        self.assertEqual(response['meta']['pages'], 1)

    def test_partial_event_filter_matches_reboot_events_in_query_and_export(self):
        self.write_rows('.1', [
            {'timestamp': '2026-10-14T23:00:00+00:00', 'event': 'cpe_reboot_attempt'},
        ])
        self.write_rows('', [
            {'timestamp': '2026-10-15T01:00:00+00:00', 'event': 'cpe_reboot_failed'},
            {'timestamp': '2026-10-15T02:00:00+00:00', 'event': 'cpe_reboot_acknowledged'},
            {'timestamp': '2026-10-15T03:00:00+00:00', 'event': 'openwrt_reboot_requested'},
            {'timestamp': '2026-10-15T04:00:00+00:00', 'event': 'https_probe', 'reason': 'reboot'},
        ])
        response = self.history.query({'event': 'reboot', 'date': '2026-10-15',
            'page': 2, 'page_size': 1}, base_path=self.path)
        self.assertEqual(response['meta']['total'], 3)
        self.assertEqual([row['event'] for row in response['records']], ['cpe_reboot_acknowledged'])
        exported = self.history.export_chunk({'event': 'reboot'}, base_path=self.path)
        self.assertEqual(exported['total'], 4)
        self.assertEqual([json.loads(line)['event'] for line in exported['data'].splitlines()],
            ['openwrt_reboot_requested', 'cpe_reboot_acknowledged', 'cpe_reboot_failed', 'cpe_reboot_attempt'])

    def test_pagination_reports_empty_out_of_range_page_with_bounds(self):
        self.fixture_history()

        response = self.history.query({'page': 4, 'page_size': 2}, base_path=self.path)

        self.assertEqual(response['records'], [])
        self.assertEqual(response['meta'], {
            'available': 5, 'total': 5, 'page': 4, 'page_size': 2,
            'pages': 3, 'first': 0, 'last': 0,
        })

    def test_unknown_and_sensitive_fields_never_reach_query_or_export(self):
        self.fixture_history()

        queried = self.history.query({'page': 1, 'page_size': 10}, base_path=self.path)
        exported = self.history.export_chunk({'offset': 0, 'limit': 10}, base_path=self.path)
        serialized = json.dumps(queried, sort_keys=True) + exported['data']

        for forbidden in (
                'password', 'archive-secret', 'cookie', 'archive-cookie',
                'token', 'archive-token', 'username', 'router-admin',
                'cookies', 'session-secret', 'nested_unknown', 'nested-secret',
                'NaN'):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, serialized)
        self.assertEqual(exported['count'], 5)
        self.assertIsNone(exported['next_offset'])
        self.assertTrue(exported['data'].endswith('\n'))

    def test_chunked_export_can_collect_the_complete_filtered_history(self):
        self.fixture_history()
        chunks = []
        offset = 0
        while True:
            response = self.history.export_chunk({
                'offset': offset, 'limit': 2, 'event': 'probe',
            }, base_path=self.path)
            chunks.append(response['data'])
            if response['next_offset'] is None:
                break
            offset = response['next_offset']

        rows = [json.loads(line) for line in ''.join(chunks).splitlines()]
        self.assertEqual([row['timestamp'] for row in rows], [
            '2026-10-15T01:00:00+00:00', '2026-10-13T09:00:00+00:00',
        ])
        self.assertEqual(response['available'], 5)
        self.assertEqual(response['total'], 2)

    def test_rejects_non_numeric_unbounded_and_path_parameters(self):
        invalid_queries = [
            {'page': '1'}, {'page': True}, {'page': 0},
            {'page_size': 0}, {'page_size': 101}, {'date': '2026-02-30'},
            {'event': '../events.jsonl'}, {'event': 'x' * 65},
            {'path': '/etc/cpe-watchdog/credentials'},
        ]
        invalid_exports = [
            {'offset': -1}, {'offset': '0'}, {'limit': 0}, {'limit': 501},
            {'filename': '../../credentials'},
        ]

        for params in invalid_queries:
            with self.subTest(query=params), self.assertRaises(self.history.InvalidParams):
                self.history.query(params, base_path=self.path)
        for params in invalid_exports:
            with self.subTest(export=params), self.assertRaises(self.history.InvalidParams):
                self.history.export_chunk(params, base_path=self.path)

    def test_rpcd_wrapper_lists_only_read_methods_and_returns_json_errors(self):
        listed = subprocess.run(
            [sys.executable, str(RPC), 'list'], check=True,
            text=True, capture_output=True,
        )
        contract = json.loads(listed.stdout)
        self.assertEqual(set(contract), {'query', 'export'})
        self.assertIs(type(contract['query']['page']), int)
        self.assertEqual(contract['query']['date'], '')
        self.assertNotIn('path', json.dumps(contract))

        called = subprocess.run(
            [sys.executable, str(RPC), 'call', 'query'], input='{"page":"one"}',
            check=True, text=True, capture_output=True,
        )
        self.assertEqual(json.loads(called.stdout), {
            'error': 'invalid_params', 'message': 'page must be an integer',
        })
        http_call = subprocess.run(
            [sys.executable, str(RPC), 'call', 'query'],
            input='{"page":1,"ubus_rpc_session":"fixture-session"}',
            check=True, text=True, capture_output=True)
        self.assertIn('records', json.loads(http_call.stdout))
        self.assertNotIn('fixture-session', http_call.stdout)

    def test_export_rejects_changed_history_instead_of_silently_skipping_rows(self):
        first = self.history.export_chunk({'limit': 1}, base_path=self.path)
        self.assertEqual(len(first['snapshot']), 64)
        with self.path.open('a') as file:
            file.write(json.dumps({'timestamp': '2026-10-15T12:00:00+00:00', 'event': 'new'}) + '\n')
        with self.assertRaises(self.history.InvalidParams):
            self.history.export_chunk({'offset': 1, 'snapshot': first['snapshot']}, base_path=self.path)


if __name__ == '__main__':
    unittest.main()
