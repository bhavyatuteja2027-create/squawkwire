"""Sentiment scoring.

Two backends behind one interface:
  - keyword: the prototype's lexicon scorer (no ML deps, always available — the fallback).
  - finbert: ProsusAI/finbert via transformers, BATCHED (brief section 6.6).

`score_batch(titles)` returns a list of (score, probs) where score is -1..+1 and probs is
{"pos","neg","neu"} or None (keyword backend has no probabilities). The backend is chosen by
config.SENTIMENT_BACKEND; FinBERT falls back to keyword if the model can't load.
"""
import re

from . import config

POS = "beat beats raises raised surge surges rally record upgrade strong gain gains growth profit approval wins eases".split()
NEG = "cut cuts miss misses falls fall drop drops plunge slump downgrade weak loss losses probe recall layoffs warning delay tariff default".split()


def keyword_score(title):
    w = re.findall(r"[a-z']+", title.lower())
    p, n = sum(x in POS for x in w), sum(x in NEG for x in w)
    return round(max(-1, min(1, (p - n) / (p + n + 1) * 1.2)), 2)


# ---- FinBERT (lazy; imported only if selected and installed) ----
_pipe = None
_finbert_failed = False


def _load_finbert():
    global _pipe, _finbert_failed
    if _pipe is not None or _finbert_failed:
        return _pipe
    try:
        from transformers import pipeline  # heavy; only on the always-on worker
        _pipe = pipeline("text-classification", model=config.HF_MODEL_ID,
                         top_k=None, truncation=True)
    except Exception as e:  # missing deps, no network, OOM -> permanent fallback
        print(f"[score] FinBERT unavailable ({type(e).__name__}); using keyword scorer")
        _finbert_failed = True
        _pipe = None
    return _pipe


def _finbert_batch(titles):
    pipe = _load_finbert()
    if pipe is None:
        return [(keyword_score(t), None) for t in titles]
    out = []
    # transformers batches internally; pass the whole list.
    results = pipe(titles, batch_size=min(32, len(titles)))
    for res in results:
        probs = {d["label"].lower(): float(d["score"]) for d in res}
        pos, neg, neu = probs.get("positive", 0.0), probs.get("negative", 0.0), probs.get("neutral", 0.0)
        score = round(max(-1.0, min(1.0, pos - neg)), 3)  # map to -1..+1
        out.append((score, {"pos": round(pos, 4), "neg": round(neg, 4), "neu": round(neu, 4)}))
    return out


def score_batch(titles):
    if not titles:
        return []
    if config.SENTIMENT_BACKEND == "finbert":
        return _finbert_batch(titles)
    return [(keyword_score(t), None) for t in titles]
