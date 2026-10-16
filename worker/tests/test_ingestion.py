"""Unit tests for the ingestion money-path logic (brief section 13).
Run: python -m unittest discover -s worker/tests  (from repo root)
Uses the keyword backend so no ML deps are needed.
"""
import os, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from squawkwire import parse, score  # noqa: E402


class TestCategorize(unittest.TestCase):
    def test_rules_match_before_default(self):
        self.assertEqual(parse.categorize("Fed holds interest rate decision", "X"), "Central Banks")
        self.assertEqual(parse.categorize("Bitcoin and ethereum surge", "X"), "Crypto")
        self.assertEqual(parse.categorize("OPEC cuts oil output", "X"), "Commodities")
        self.assertEqual(parse.categorize("CPI inflation cools", "X"), "Macro")
        self.assertEqual(parse.categorize("Dollar rises vs yen", "X"), "FX")
        self.assertEqual(parse.categorize("Ceasefire talks in summit", "X"), "World")

    def test_default_when_no_rule(self):
        self.assertEqual(parse.categorize("Company unveils new gadget", "Equities"), "Equities")


class TestDedupeCanonical(unittest.TestCase):
    def test_tracking_params_stripped(self):
        a = parse.url_hash("https://x.com/story?utm_source=tw&id=5")
        b = parse.url_hash("https://x.com/story?id=5")
        self.assertEqual(a, b)

    def test_distinct_urls_differ(self):
        self.assertNotEqual(parse.url_hash("https://x.com/a"), parse.url_hash("https://x.com/b"))

    def test_hash_is_short_hex(self):
        h = parse.url_hash("https://x.com/a")
        self.assertEqual(len(h), 12)
        int(h, 16)  # raises if not hex


class TestKeywordScore(unittest.TestCase):
    def test_bullish_positive(self):
        self.assertGreater(score.keyword_score("stocks rally to record high on strong growth"), 0.15)

    def test_bearish_negative(self):
        self.assertLess(score.keyword_score("shares plunge on profit warning and layoffs"), -0.15)

    def test_neutral_near_zero(self):
        self.assertTrue(-0.15 <= score.keyword_score("company holds annual meeting today") <= 0.15)

    def test_bounds(self):
        for t in ["surge " * 20, "plunge " * 20, ""]:
            s = score.keyword_score(t)
            self.assertTrue(-1.0 <= s <= 1.0)

    def test_score_batch_keyword(self):
        out = score.score_batch(["profit beats surge", "losses plunge warning"])
        self.assertEqual(len(out), 2)
        self.assertGreater(out[0][0], 0)
        self.assertLess(out[1][0], 0)
        self.assertIsNone(out[0][1])  # keyword backend has no probs


class TestEntities(unittest.TestCase):
    def test_cashtag_extracted(self):
        # Works offline even if the SEC map didn't load — cashtags always parse.
        from squawkwire import entities
        got = entities.extract("$TSLA jumps after earnings")
        tickers = {e["ticker"] for e in got}
        self.assertIn("TSLA", tickers)

    def test_stopwords_not_tickers(self):
        from squawkwire import entities
        got = entities.extract("The CEO discusses GDP and CPI")
        self.assertEqual([e for e in got if e["ticker"] in ("CEO", "GDP", "CPI")], [])


if __name__ == "__main__":
    unittest.main()
