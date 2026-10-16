// POST /api/billing/checkout  { plan: "retail" | "pro" }
// Auth: Authorization: Bearer <supabase access token>.
// Creates a Stripe hosted Checkout session and returns { url } to redirect to.
// The user_id is carried in Stripe metadata; entitlements change ONLY via the webhook.
import { admin, requireUser, json, rawBody } from '../_lib/supa.js';
import { stripeProvider } from '../_lib/payments.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'method_not_allowed' });

  const user = await requireUser(req);
  if (!user) return json(res, 401, { error: 'unauthorized' });

  let body = {};
  try { body = JSON.parse((await rawBody(req)).toString() || '{}'); } catch { /* ignore */ }
  const planCode = body.plan;
  if (!['retail', 'pro'].includes(planCode)) return json(res, 400, { error: 'invalid_plan' });

  const db = admin();

  // Resolve the plan's Stripe price id from the DB (seeded in plans.provider_price_id).
  const { data: plan } = await db.from('plans')
    .select('provider_price_id').eq('code', planCode).single();
  if (!plan?.provider_price_id) return json(res, 500, { error: 'plan_not_configured' });

  // Reuse an existing Stripe customer id if we already linked one.
  const { data: sub } = await db.from('subscriptions')
    .select('provider_customer_id').eq('user_id', user.id)
    .not('provider_customer_id', 'is', null).limit(1).maybeSingle();

  const base = process.env.APP_BASE_URL || `https://${req.headers.host}`;
  const provider = stripeProvider();

  let result;
  try {
    result = await provider.createCheckout({
      userId: user.id,
      email: user.email,
      priceId: plan.provider_price_id,
      customerId: sub?.provider_customer_id || undefined,
      successUrl: `${base}/?billing=success`,
      cancelUrl: `${base}/?billing=cancel`,
    });
  } catch (e) {
    return json(res, 502, { error: 'stripe_error', detail: String(e.message || e) });
  }

  // Link the customer id now so the webhook can map customer -> user even if it races.
  await db.rpc('link_customer', { p_user: user.id, p_customer: result.customerId });

  return json(res, 200, { url: result.url });
}
