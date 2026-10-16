import './globals.css';
import Script from 'next/script';
import { headers } from 'next/headers';

export const metadata = {
  title: 'Squawkwire Live',
  description: 'Real-time financial news terminal. Automated analysis, not investment advice.',
};

export const viewport = { width: 'device-width', initialScale: 1 };

export default function RootLayout({ children }) {
  const nonce = headers().get('x-nonce') || undefined;
  return (
    <html lang="en">
      <body>
        {children}
        {/* Cloudflare Turnstile (bot protection on auth). Loaded once, used by the gate.
            nonce lets it pass the nonce-based CSP set in middleware.js. */}
        <Script
          src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
          strategy="afterInteractive"
          nonce={nonce}
        />
      </body>
    </html>
  );
}
