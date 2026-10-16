# Root-level build for Railway (ingestion worker). Build context is the repo root; this copies
# only the worker/ package. Railway reads the sibling railway.json (builder: DOCKERFILE) and
# uses this file, bypassing npm auto-detection from the root package-lock.json.
# Keyword sentiment backend only (no ML deps) → tiny image. Set SENTIMENT_BACKEND=keyword.
FROM python:3.12-slim

WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Keyword backend uses ONLY the Python standard library — no pip install needed.
# If you switch to SENTIMENT_BACKEND=finbert, uncomment the two lines below (installs
# torch+transformers, ~800MB; use a larger Railway instance):
#   COPY worker/requirements.txt .
#   RUN pip install -r requirements.txt

COPY worker/squawkwire ./squawkwire

# Always-on continuous polling. For a one-shot cron run use: python -m squawkwire.worker --once
CMD ["python", "-m", "squawkwire.worker"]
