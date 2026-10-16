// PaymentProvider interface + Stripe implementation (unchanged from the standalone API).
// Razorpay can be added later behind the same interface. Server-only; secrets from env.
import Stripe from 'stripe';

export function stripeProvider() {
  const secret = process.env.STRIPE_SECRET_KEY;
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!secret) throw new Error('STRIPE_SECRET_KEY not set');
  const stripe = new Stripe(secret, { apiVersion: '2024-06-20' });

  return {
    async createCheckout({ userId, email, priceId, customerId, successUrl, cancelUrl }) {
      let custId = customerId;
      if (!custId) {
        const customer = await stripe.customers.create({ email, metadata: { user_id: userId } });
        custId = customer.id;
      }
      const session = await stripe.checkout.sessions.create({
        mode: 'subscription',
        customer: custId,
        line_items: [{ price: priceId, quantity: 1 }],
        subscription_data: { metadata: { user_id: userId } },
        metadata: { user_id: userId },
        success_url: successUrl,
        cancel_url: cancelUrl,
        allow_promotion_codes: true,
      });
      return { url: session.url, customerId: custId };
    },

    async createPortal({ customerId, returnUrl }) {
      const session = await stripe.billingPortal.sessions.create({ customer: customerId, return_url: returnUrl });
      return { url: session.url };
    },

    verifyWebhook(rawBody, signature) {
      if (!webhookSecret) throw new Error('STRIPE_WEBHOOK_SECRET not set');
      return stripe.webhooks.constructEvent(rawBody, signature, webhookSecret);
    },

    parseEvent(event) {
      const t = event.type;
      const o = event.data?.object || {};
      if (t === 'checkout.session.completed') {
        return { kind: 'checkout_completed', userId: o.metadata?.user_id, customerId: o.customer, subscriptionId: o.subscription };
      }
      if (t === 'customer.subscription.created' || t === 'customer.subscription.updated' || t === 'customer.subscription.deleted') {
        const item = o.items?.data?.[0];
        return {
          kind: 'subscription',
          customerId: o.customer,
          subscriptionId: o.id,
          priceId: item?.price?.id || null,
          status: t === 'customer.subscription.deleted' ? 'canceled' : o.status,
          periodEnd: o.current_period_end ? new Date(o.current_period_end * 1000).toISOString() : null,
          cancelAtPeriodEnd: !!o.cancel_at_period_end,
        };
      }
      if (t === 'invoice.paid' || t === 'invoice.payment_failed') {
        return {
          kind: 'invoice',
          customerId: o.customer,
          paymentId: o.payment_intent || o.id,
          amount: o.amount_paid ?? o.amount_due ?? null,
          currency: o.currency,
          status: t === 'invoice.paid' ? 'paid' : 'failed',
          invoiceUrl: o.hosted_invoice_url || null,
        };
      }
      return null;
    },
  };
}
