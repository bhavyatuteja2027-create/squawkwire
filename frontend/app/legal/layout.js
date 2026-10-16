export const metadata = { title: 'Legal — Squawkwire' };

export default function LegalLayout({ children }) {
  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '40px 20px', lineHeight: 1.6 }}>
      <a href="/" style={{ display: 'inline-block', marginBottom: 20, color: 'var(--brand)' }}>← Back to Squawkwire</a>
      <p style={{ background: 'var(--head)', border: '1px solid var(--hot)', borderRadius: 8, padding: '12px 14px', color: 'var(--hot)', fontSize: 13 }}>
        <strong>Template — not legal advice.</strong> Replace the bracketed placeholders and have a
        qualified lawyer in your jurisdiction review this before you charge users or launch.
      </p>
      {children}
      <p style={{ color: 'var(--muted)', marginTop: 32 }}>
        <a href="/legal/disclaimer" style={{ color: 'var(--brand)' }}>Disclaimer</a> ·{' '}
        <a href="/legal/terms" style={{ color: 'var(--brand)' }}>Terms</a> ·{' '}
        <a href="/legal/privacy" style={{ color: 'var(--brand)' }}>Privacy</a>
      </p>
    </main>
  );
}
