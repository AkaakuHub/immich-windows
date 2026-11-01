import http.client
import io
import unittest
import urllib.error
import urllib.request
from unittest.mock import Mock, patch

from automation import transport


class ReadRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.request = urllib.request.Request('https://api.github.com/repos/example/repo/releases/latest')
        self.sleep = patch.object(transport.time, 'sleep').start()
        self.addCleanup(patch.stopall)

    def error(self, code, headers=None):
        return urllib.error.HTTPError(self.request.full_url, code, 'fixture', headers or {}, None)

    def test_temporary_failures_retry_the_read_then_return_its_result(self):
        for failure in (self.error(503), TimeoutError(), urllib.error.URLError('temporary'),
                        http.client.IncompleteRead(b'', 10)):
            with self.subTest(failure=type(failure)):
                opener = Mock(side_effect=[failure, io.BytesIO(b'{"ok":true}')])
                self.assertEqual(transport.read_json(opener, self.request), {'ok': True})
                self.assertEqual(opener.call_count, 2)

    def test_persistent_network_failure_is_bounded(self):
        opener = Mock(side_effect=self.error(502))
        with self.assertRaises(urllib.error.HTTPError):
            transport.read_json(opener, self.request)
        self.assertEqual(opener.call_count, 3)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [2, 4])

    def test_rate_limit_waits_until_retry_after(self):
        opener = Mock(side_effect=[self.error(429, {'Retry-After': '8'}), io.BytesIO(b'{}')])
        transport.read_json(opener, self.request)
        self.sleep.assert_called_once_with(8)

    def test_service_unavailable_respects_retry_after(self):
        opener = Mock(side_effect=[self.error(503, {'Retry-After': '10'}), io.BytesIO(b'{}')])
        transport.read_json(opener, self.request)
        self.sleep.assert_called_once_with(10)

    def test_both_rate_limit_headers_use_the_later_time(self):
        opener = Mock(side_effect=[self.error(403, {'Retry-After': '5', 'X-RateLimit-Remaining': '0',
                                                   'X-RateLimit-Reset': '1010'}), io.BytesIO(b'{}')])
        with patch.object(transport.time, 'time', return_value=1000):
            transport.read_json(opener, self.request)
        self.sleep.assert_called_once_with(11)

    def test_primary_rate_limit_waits_until_reset(self):
        opener = Mock(side_effect=[self.error(403, {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1010'}),
                                   io.BytesIO(b'{}')])
        with patch.object(transport.time, 'time', return_value=1000):
            transport.read_json(opener, self.request)
        self.sleep.assert_called_once_with(11)

    def test_long_rate_limits_are_not_retried_early(self):
        opener = Mock(side_effect=self.error(429, {'Retry-After': '120'}))
        with self.assertRaises(urllib.error.HTTPError):
            transport.read_json(opener, self.request)
        opener.assert_called_once()
        self.sleep.assert_not_called()

    def test_permissions_missing_resources_and_redirects_are_not_retried(self):
        for code in (301, 302, 401, 403, 404, 409, 422, 429):
            with self.subTest(code=code):
                opener = Mock(side_effect=self.error(code))
                with self.assertRaises(urllib.error.HTTPError):
                    transport.read_json(opener, self.request)
                opener.assert_called_once()
        self.sleep.assert_not_called()

    def test_writes_are_never_replayed(self):
        opener = Mock()
        request = urllib.request.Request(self.request.full_url, data=b'{}', method='POST')
        with self.assertRaises(ValueError):
            transport.read_json(opener, request)
        opener.assert_not_called()

    def test_invalid_json_is_not_hidden_by_a_retry(self):
        opener = Mock(return_value=io.BytesIO(b'invalid'))
        with self.assertRaises(ValueError):
            transport.read_json(opener, self.request)
        opener.assert_called_once()
