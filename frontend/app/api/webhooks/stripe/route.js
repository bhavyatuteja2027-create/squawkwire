// POST /api/webhooks/stripe  (no auth header — authenticity is the Stripe signature)
// App Router gives us the raw body via request.text(), so no bodyParser config is needed.
// Verifies signature, dedupes via claim_webhook_event, then drives subscriptions/payments.
import { admin } from '@/lib/supabaseServer';
import { stripeProvider } from '@/lib/payments';

export const runtime = 'nodejs';

export async function POST(request) {
  const sig = request.headers.get('stripe-signature');
  const raw = await request.text();

  const provider = stripeProvider();
  let event;
  try {
    event = provider.verifyWebhook(raw, sig);
  } catch (e) {
    return Response.json({ error: 'invalid_signature', detail: String(e.message || e) }, { status: 400 });
  }

  const db = admin();
  const { data: firstTime, error: claimErr } = await db.rpc('claim_webhook_event', {
    p_provider: 'stripe', p_event_id: event.id, p_type: event.type, p_payload: event,
  });
  if (claimErr) return Response.json({ error: 'claim_failed' }, { status: 500 });
  if (!firstTime) return Response.json({ received: true, duplicate: true });

  const parsed = provider.parseEvent(event);
  try {
    if (parsed?.kind === 'checkout_completed') {
      if (parsed.userId && parsed.customerId) await db.rpc('link_customer', { p_user: parsed.userId, p_customer: parsed.customerId });
    } else if (parsed?.kind === 'subscription') {
      await db.rpc('upsert_subscription', {
        p_customer: parsed.customerId, p_subscription: parsed.subscriptionId, p_price_id: parsed.priceId,
        p_status: parsed.status, p_period_end: parsed.periodEnd, p_cancel_at_end: parsed.cancelAtPeriodEnd,
      });
    } else if (parsed?.kind === 'invoice') {
      await db.rpc('record_payment', {
        p_customer: parsed.customerId, p_payment_id: parsed.paymentId, p_amount: parsed.amount,
        p_currency: parsed.currency, p_status: parsed.status, p_invoice_url: parsed.invoiceUrl,
      });
    }
  } catch (e) {
    // Release the claim so Stripe's retry reprocesses (RPCs are idempotent).
    await db.rpc('release_webhook_event', { p_provider: 'stripe', p_event_id: event.id });
    return Response.json({ error: 'processing_failed', detail: String(e.message || e) }, { status: 500 });
  }

  return Response.json({ received: true });
}
