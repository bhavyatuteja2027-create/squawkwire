// POST /api/webhooks/stripe  (no auth header — authenticity is the Stripe signature)
// Verifies the signature on the RAW body, dedupes via claim_webhook_event, then drives
// subscriptions/payments. This is the ONLY place entitlements change (brief section 9).
import { admin, json, rawBody } from '../_lib/supa.js';
import { stripeProvider } from '../_lib/payments.js';

// Vercel: we must read the raw body for signature verification, so disable body parsing.
export const config = { api: { bodyParser: false } };

export default async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'method_not_allowed' });

  const sig = req.headers['stripe-signature'];
  const buf = await rawBody(req);

  const provider = stripeProvider();
  let event;
  try {
    event = provider.verifyWebhook(buf, sig); // throws on bad/missing signature
  } catch (e) {
    return json(res, 400, { error: 'invalid_signature', detail: String(e.message || e) });
  }

  const db = admin();

  // Idempotency: process each event id exactly once.
  const { data: firstTime, error: claimErr } = await db.rpc('claim_webhook_event', {
    p_provider: 'stripe', p_event_id: event.id, p_type: event.type, p_payload: event,
  });
  if (claimErr) return json(res, 500, { error: 'claim_failed' });
  if (!firstTime) return json(res, 200, { received: true, duplicate: true });

  const parsed = provider.parseEvent(event);
  try {
    if (parsed?.kind === 'checkout_completed') {
      if (parsed.userId && parsed.customerId) {
        await db.rpc('link_customer', { p_user: parsed.userId, p_customer: parsed.customerId });
      }
      // The subscription.created/updated event carries the plan/status; nothing else to do.
    } else if (parsed?.kind === 'subscription') {
      await db.rpc('upsert_subscription', {
        p_customer: parsed.customerId,
        p_subscription: parsed.subscriptionId,
        p_price_id: parsed.priceId,
        p_status: parsed.status,
        p_period_end: parsed.periodEnd,
        p_cancel_at_end: parsed.cancelAtPeriodEnd,
      });
    } else if (parsed?.kind === 'invoice') {
      await db.rpc('record_payment', {
        p_customer: parsed.customerId,
        p_payment_id: parsed.paymentId,
        p_amount: parsed.amount,
        p_currency: parsed.currency,
        p_status: parsed.status,
        p_invoice_url: parsed.invoiceUrl,
      });
    }
  } catch (e) {
    // Release the claim so Stripe's retry reprocesses. The RPCs are idempotent
    // (upsert by subscription id; payment deduped by payment id), so reprocessing is safe.
    await db.rpc('release_webhook_event', { p_provider: 'stripe', p_event_id: event.id });
    return json(res, 500, { error: 'processing_failed', detail: String(e.message || e) });
  }

  return json(res, 200, { received: true });
}
