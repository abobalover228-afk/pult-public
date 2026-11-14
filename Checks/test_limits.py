import json
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Resources/helpers"))
from limits import sanitize, render


class LimitsTests(unittest.TestCase):
    def test_null_primary_does_not_invent_a_five_hour_window(self):
        value = sanitize({'account': {'type': 'chatgpt', 'planType': 'plus'}},
                         {'rateLimits': {'primary': None, 'secondary': {
                             'usedPercent': 12, 'windowDurationMins': 10080, 'resetsAt': None}}})
        text = '\n'.join(render('test', value))
        self.assertIn('7 дн.', text)
        self.assertIn('осталось 88%', text)
        self.assertNotIn('5 ч.', text)
        self.assertIn('сброс не предоставлен', text)

    def test_all_buckets_are_kept_without_duplicate_legacy_bucket(self):
        value = sanitize({}, {'rateLimits': {'limitId': 'legacy'},
                              'rateLimitsByLimitId': {'codex': {'primary': None},
                                                     'review': {'secondary': None}}})
        self.assertEqual([b['name'] for b in value['limits']], ['codex', 'review'])

    def test_auth_and_credit_private_fields_are_not_exported(self):
        value = sanitize({'account': {'type': 'chatgpt', 'planType': 'plus',
                                      'email': 'private@example.invalid', 'accessToken': 'hidden'}},
                         {'rateLimits': {'credits': {'balance': '20', 'accountId': 'private-id'}}})
        text = json.dumps(value)
        for private in ('private@example.invalid', 'hidden', 'private-id'):
            self.assertNotIn(private, text)
        output = '\n'.join(render('test', value))
        self.assertIn('20 (не сумма в $)', output)

    def test_missing_or_invalid_usage_is_unknown_not_free(self):
        for used in (None, True, float('nan')):
            value = sanitize({}, {'rateLimits': {'primary': {'usedPercent': used}}})
            self.assertIn('остаток неизвестен', '\n'.join(render('test', value)))
        self.assertIn('не означает безлимит', '\n'.join(render('test', sanitize({}, {}))))

    def test_exhausted_and_fractional_quotas(self):
        value = sanitize({}, {'rateLimits': {'primary': {'usedPercent': 110},
                                            'secondary': {'usedPercent': 1.5}}})
        self.assertEqual([w['remaining_percent'] for w in value['limits'][0]['windows']], [0, 98.5])

    def test_reset_time_uses_local_timezone(self):
        value = sanitize({}, {'rateLimits': {'primary': {
            'usedPercent': 0, 'windowDurationMins': 300, 'resetsAt': 0}}})
        self.assertIn('(местное время)', '\n'.join(render('test', value)))


if __name__ == '__main__':
    unittest.main()
