"""Backwards-compatible entrypoint for the interim GitHub Actions cron.

Phase 2 moved the logic into the `squawkwire` package. This runs a single pass
(equivalent to `python -m squawkwire.worker --once`) so the existing workflow keeps working
while you stand up the always-on worker on Railway/Fly.
"""
import sys
from squawkwire import worker, config

if __name__ == "__main__":
    config.require_env()
    sys.exit(worker.run_once())
