// POST /api/billing/portal
// Auth: Authorization: Bearer <supabase access token>.
// Returns { url } to Stripe's customer billing portal (card changes, cancel, invoices).
import { admin, requireUser, json } from '../_lib/supa.js';
import { stripeProvider } from '../_lib/payments.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'method_not_allowed' });

  const user = await requireUser(req);
  if (!user) return json(res, 401, { error: 'unauthorized' });

  const db = admin();
  const { data: sub } = await db.from('subscriptions')
    .select('provider_customer_id').eq('user_id', user.id)
    .not('provider_customer_id', 'is', null).limit(1).maybeSingle();

  if (!sub?.provider_customer_id) return json(res, 400, { error: 'no_customer' });

  const base = process.env.APP_BASE_URL || `https://${req.headers.host}`;
  try {
    const { url } = await stripeProvider().createPortal({
      customerId: sub.provider_customer_id,
      returnUrl: `${base}/?billing=portal`,
    });
    return json(res, 200, { url });
  } catch (e) {
    return json(res, 502, { error: 'stripe_error', detail: String(e.message || e) });
  }
}
