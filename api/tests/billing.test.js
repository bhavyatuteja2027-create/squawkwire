// JS tests for money-path logic: Stripe webhook event normalization + entitlement delay.
// Run: node --test api/tests/   (from repo root). Node 18+ has the built-in test runner.
import { test } from 'node:test';
import assert from 'node:assert/strict';

// stripeProvider() needs a key to construct the SDK; parseEvent itself is pure.
process.env.STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY || 'sk_test_dummy';
const { stripeProvider } = await import('../_lib/payments.js');
const p = stripeProvider();

test('parseEvent: checkout.session.completed maps user + customer + subscription', () => {
  const ev = { type: 'checkout.session.completed',
    data: { object: { metadata: { user_id: 'u1' }, customer: 'cus_1', subscription: 'sub_1' } } };
  assert.deepEqual(p.parseEvent(ev),
    { kind: 'checkout_completed', userId: 'u1', customerId: 'cus_1', subscriptionId: 'sub_1' });
});

test('parseEvent: subscription.updated carries price/status/period', () => {
  const ev = { type: 'customer.subscription.updated',
    data: { object: { id: 'sub_1', customer: 'cus_1', status: 'active',
      current_period_end: 1893456000, cancel_at_period_end: true,
      items: { data: [{ price: { id: 'price_pro' } }] } } } };
  const r = p.parseEvent(ev);
  assert.equal(r.kind, 'subscription');
  assert.equal(r.priceId, 'price_pro');
  assert.equal(r.status, 'active');
  assert.equal(r.cancelAtPeriodEnd, true);
  assert.ok(r.periodEnd.startsWith('20')); // ISO date string
});

test('parseEvent: subscription.deleted forces canceled status', () => {
  const ev = { type: 'customer.subscription.deleted',
    data: { object: { id: 'sub_1', customer: 'cus_1', status: 'active', items: { data: [] } } } };
  assert.equal(p.parseEvent(ev).status, 'canceled');
});

test('parseEvent: invoice.paid vs payment_failed', () => {
  const paid = p.parseEvent({ type: 'invoice.paid',
    data: { object: { customer: 'cus_1', payment_intent: 'pi_1', amount_paid: 999, currency: 'usd', hosted_invoice_url: 'https://x' } } });
  assert.equal(paid.kind, 'invoice');
  assert.equal(paid.status, 'paid');
  assert.equal(paid.amount, 999);
  const failed = p.parseEvent({ type: 'invoice.payment_failed',
    data: { object: { customer: 'cus_1', id: 'in_1', amount_due: 999, currency: 'usd' } } });
  assert.equal(failed.status, 'failed');
});

test('parseEvent: unknown event type ignored', () => {
  assert.equal(p.parseEvent({ type: 'customer.created', data: { object: {} } }), null);
});

// Entitlement delay gate — the rule the feed_items() RPC encodes, mirrored for a unit check.
function visibleUnderDelay(publishedAtMs, delaySeconds, nowMs) {
  return publishedAtMs <= nowMs - delaySeconds * 1000;
}
test('entitlement delay: free (24h) hides fresh, shows old; paid (0) shows all', () => {
  const now = Date.now();
  const fresh = now - 60 * 1000;          // 1 min old
  const old = now - 25 * 3600 * 1000;     // 25h old
  assert.equal(visibleUnderDelay(fresh, 86400, now), false); // free hides fresh
  assert.equal(visibleUnderDelay(old, 86400, now), true);    // free shows >24h
  assert.equal(visibleUnderDelay(fresh, 0, now), true);      // paid shows fresh
});
