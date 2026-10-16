// POST /api/billing/portal  → { url } to Stripe's customer billing portal.
import { admin, requireUser } from '@/lib/supabaseServer';
import { stripeProvider } from '@/lib/payments';

export const runtime = 'nodejs';

export async function POST(request) {
  const user = await requireUser(request);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });

  const db = admin();
  const { data: sub } = await db.from('subscriptions').select('provider_customer_id')
    .eq('user_id', user.id).not('provider_customer_id', 'is', null).limit(1).maybeSingle();
  if (!sub?.provider_customer_id) return Response.json({ error: 'no_customer' }, { status: 400 });

  const base = process.env.APP_BASE_URL || new URL(request.url).origin;
  try {
    const { url } = await stripeProvider().createPortal({ customerId: sub.provider_customer_id, returnUrl: `${base}/?billing=portal` });
    return Response.json({ url });
  } catch (e) {
    return Response.json({ error: 'stripe_error', detail: String(e.message || e) }, { status: 502 });
  }
}
