export const metadata = { title: 'Privacy Policy — Squawkwire' };

export default function Privacy() {
  return (
    <>
      <h1>Privacy Policy</h1>
      <h2>Who we are</h2>
      <p>[COMPANY LEGAL NAME], [JURISDICTION], operates Squawkwire. Contact: [CONTACT EMAIL].</p>
      <h2>What we collect</h2>
      <ul>
        <li><strong>Account data:</strong> email, display name, timezone.</li>
        <li><strong>Usage data:</strong> your dashboards, widgets, watch keywords and alert rules.</li>
        <li><strong>Billing data:</strong> subscription status and payment metadata. Card details
        are handled solely by Stripe; we never store card numbers.</li>
        <li><strong>Technical data:</strong> standard logs and error telemetry.</li>
      </ul>
      <h2>How we use it</h2>
      <p>To provide the Service, process subscriptions, secure it (including bot protection), and
      improve the product. We do not sell your personal data.</p>
      <h2>Processors we use</h2>
      <p>Supabase (auth, database, realtime), Stripe (payments), our email provider, Cloudflare
      Turnstile (bot protection), and Vercel (hosting).</p>
      <h2>Your rights</h2>
      <p>Depending on your jurisdiction you may request access, correction, export or deletion of
      your data. Contact us or use account settings.</p>
      <h2>Retention &amp; security</h2>
      <p>We keep account and billing data while your account is active and as required by law. We
      use encryption in transit, row-level access controls and least-privilege server keys.</p>
    </>
  );
}
