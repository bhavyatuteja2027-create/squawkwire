// POST /api/billing/checkout  { plan: "retail" | "pro" }
// Auth: Authorization: Bearer <supabase access token>. Returns { url } for Stripe Checkout.
import { admin, requireUser } from '@/lib/supabaseServer';
import { stripeProvider } from '@/lib/payments';

export const runtime = 'nodejs';

export async function POST(request) {
  const user = await requireUser(request);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });

  let body = {};
  try { body = await request.json(); } catch { /* ignore */ }
  const planCode = body.plan;
  if (!['retail', 'pro'].includes(planCode)) return Response.json({ error: 'invalid_plan' }, { status: 400 });

  const db = admin();
  const { data: plan } = await db.from('plans').select('provider_price_id').eq('code', planCode).single();
  if (!plan?.provider_price_id) return Response.json({ error: 'plan_not_configured' }, { status: 500 });

  const { data: sub } = await db.from('subscriptions').select('provider_customer_id')
    .eq('user_id', user.id).not('provider_customer_id', 'is', null).limit(1).maybeSingle();

  const base = process.env.APP_BASE_URL || new URL(request.url).origin;
  try {
    const result = await stripeProvider().createCheckout({
      userId: user.id, email: user.email, priceId: plan.provider_price_id,
      customerId: sub?.provider_customer_id || undefined,
      successUrl: `${base}/?billing=success`, cancelUrl: `${base}/?billing=cancel`,
    });
    await db.rpc('link_customer', { p_user: user.id, p_customer: result.customerId });
    return Response.json({ url: result.url });
  } catch (e) {
    return Response.json({ error: 'stripe_error', detail: String(e.message || e) }, { status: 502 });
  }
}
