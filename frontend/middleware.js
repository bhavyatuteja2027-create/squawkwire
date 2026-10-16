import { NextResponse } from 'next/server';

// Nonce-based Content-Security-Policy. Next.js App Router emits inline bootstrap/hydration
// <script> tags; a strict `script-src 'self'` blocks them. The official fix is a per-request
// nonce: Next automatically stamps this nonce onto its inline scripts (it reads the CSP from
// the request headers we set below). In dev we also allow 'unsafe-eval'/'unsafe-inline' for
// React Fast Refresh / webpack HMR. 'strict-dynamic' lets the nonce'd loader pull in trusted
// external scripts (e.g. Turnstile) in supporting browsers.
export function middleware(request) {
  const isDev = process.env.NODE_ENV !== 'production';
  const nonce = btoa(crypto.randomUUID());

  const scriptSrc = isDev
    ? `'self' 'unsafe-eval' 'unsafe-inline' https://challenges.cloudflare.com`
    : `'self' 'nonce-${nonce}' 'strict-dynamic' https://challenges.cloudflare.com`;

  const csp = [
    `default-src 'self'`,
    `script-src ${scriptSrc}`,
    `style-src 'self' 'unsafe-inline'`,
    `img-src 'self' data: https:`,
    `font-src 'self' data:`,
    `connect-src 'self' https://*.supabase.co wss://*.supabase.co https://challenges.cloudflare.com`,
    `frame-src https://challenges.cloudflare.com https://js.stripe.com`,
    `frame-ancestors 'none'`,
    `base-uri 'self'`,
    `form-action 'self'`,
    `object-src 'none'`,
    `upgrade-insecure-requests`,
  ].join('; ');

  // Pass the nonce + CSP to the app via request headers so Next can apply the nonce to its
  // inline scripts, and also set the CSP on the response for the browser.
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set('x-nonce', nonce);
  requestHeaders.set('Content-Security-Policy', csp);

  const response = NextResponse.next({ request: { headers: requestHeaders } });
  response.headers.set('Content-Security-Policy', csp);
  return response;
}

// Run on all routes except static assets and image optimizer (no inline scripts there).
export const config = {
  matcher: [
    {
      source: '/((?!_next/static|_next/image|favicon.ico).*)',
      missing: [
        { type: 'header', key: 'next-router-prefetch' },
        { type: 'header', key: 'purpose', value: 'prefetch' },
      ],
    },
  ],
};
