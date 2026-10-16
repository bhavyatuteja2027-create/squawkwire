# Easy Squawk ingestion worker (always-on: Railway / Fly / Cloud Run).
# Default build installs FinBERT deps. For a tiny keyword-only image, set
# SENTIMENT_BACKEND=keyword and comment out the pip install line.
FROM python:3.12-slim

WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/app/.hf

COPY requirements.txt .
# Install ML deps (skip if you only use the keyword backend).
RUN pip install -r requirements.txt

COPY easysquawk ./easysquawk

# Continuous polling (always-on). Override with ["python","-m","easysquawk.worker","--once"] for cron.
CMD ["python", "-m", "easysquawk.worker"]
