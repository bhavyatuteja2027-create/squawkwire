import './globals.css';
import Script from 'next/script';

export const metadata = {
  title: 'Easy Squawk Live',
  description: 'Real-time financial news terminal. Automated analysis, not investment advice.',
};

export const viewport = { width: 'device-width', initialScale: 1 };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        {children}
        {/* Cloudflare Turnstile (bot protection on auth). Loaded once, used by the gate. */}
        <Script
          src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
          strategy="afterInteractive"
        />
      </body>
    </html>
  );
}
