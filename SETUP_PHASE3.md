# Squawkwire — Phase 3: alert rules, matcher, in-app + email alerts

Adds keyword/ticker **alert rules**, a server-side **matcher** that runs in the worker right
after each item is ingested, **in-app** delivery (realtime toast + chime + squawk) and **email**
delivery via Resend, with per-channel **rate limits** and **quiet hours**. Channels are gated by
the user's plan. Prereq: Phases 1 & 2 deployed.

---

## 1. Database

Run the migration:

```
supabase/migrations/0005_alerts.sql
```

Adds `notification_prefs` (quiet hours + per-channel hourly caps), a `payload` column on
`alert_deliveries`, and RPCs:
- `match_alerts(item_id)` — service-role; the matcher (word-boundary term match on title OR
  ticker match via `item_entities`, AND `|score| >= min_abs_score`; channels intersected with
  the plan's allowed channels; dedupe on `(rule_id,item_id,channel)`; quiet-hours rows created
  `skipped`).
- `claim_pending_emails(limit)` / `mark_delivery(id,status,error)` — service-role; email queue.
- `in_quiet_hours(user)` — timezone-aware.
- `my_recent_alerts(limit)` — authenticated; backfill for the toast feed.

**Enable Realtime on `alert_deliveries`** (Database → Replication → add `public.alert_deliveries`
to the `supabase_realtime` publication). RLS already restricts rows to the user's own rules, so
the in-app toast stream is scoped per user.

---

## 2. Worker

- The matcher is called automatically: `worker.py::_ingest_batch` runs `db.match_alerts(item_id)`
  after each item + its entities are stored. No separate process.
- **Email sender** (`squawkwire/email_sender.py`, Resend): `run_once` flushes once at the end of a
  pass; `run_forever` flushes every ~20s. If `EMAIL_API_KEY` is unset, email is a no-op and
  deliveries stay `pending` (safe — turn it on later).

New worker env (add to Railway/Fly secrets):

| Var | Purpose |
|---|---|
| `EMAIL_API_KEY` | Resend API key (`re_...`) |
| `EMAIL_FROM` | Verified sender, e.g. `Squawkwire <alerts@yourdomain.com>` |
| `APP_BASE_URL` | Optional link back to the terminal in the email |

---

## 3. Frontend

Watchlists page gains:
- **Alert rules**: term or `$TICKER`, minimum strength, and channel checkboxes. Channels not in
  the user's plan are disabled with a 🔒 (server enforces regardless).
- **Quiet hours**: start/end local hour → saved to `notification_prefs`.
- **In-app toasts**: subscribes to `alert_deliveries` (channel `in_app`) via Realtime; each new
  match pops a toast (bottom-right) with chime, and speaks it if Squawk is on.

---

## 4. Phase 3 test checklist

**Matcher**
- [ ] Create a rule `Fed` (in_app). Ingest a headline containing "Fed" → an `alert_deliveries`
      row (channel `in_app`, status `sent`) appears for your rule.
- [ ] Word boundaries: a rule `oil` does NOT match "foil" or "coiled".
- [ ] Ticker rule `NVDA` matches a headline where `item_entities` has NVDA, even if the title
      doesn't contain the literal term.
- [ ] `min_abs_score = 0.5` rule does NOT fire on a weak-score headline.
- [ ] Dedupe: re-ingesting the same item does not create a second delivery for the same
      (rule, item, channel).

**Entitlements**
- [ ] A Free user can only select `in_app`; email/push/webhook/telegram are 🔒 disabled, and the
      matcher does not create those deliveries even if forced.
- [ ] A Pro user can select all channels.

**In-app delivery**
- [ ] With the app open, a new match pops a toast within a few seconds; chime plays; if Squawk is
      on, it is spoken. Toast auto-dismisses.

**Email**
- [ ] With `EMAIL_API_KEY` set and an email rule, a match sends an email (check Resend dashboard);
      the delivery flips `pending → sent`.
- [ ] Rate limit: exceeding `email_max_per_hour` (default 20) leaves further deliveries `pending`
      until the window rolls.
- [ ] Quiet hours: set quiet hours covering now → new email/push deliveries are created `skipped`,
      in-app still fires.

---

## Open follow-ups (Phase 4+)

- Web Push (VAPID) + Telegram + webhook senders — same `alert_deliveries` queue pattern; add a
  sender per channel. Only `in_app` and `email` are wired in Phase 3.
- Per-stock sentiment weighting of the match score.
- Payments/entitlements go live in Phase 4; until then everyone is on Free (`in_app` only) unless
  you manually set a subscription's `plan_id`.
