/** @type {import('next').NextConfig} */
// Static security headers. The Content-Security-Policy is intentionally NOT here — it is set
// per-request in middleware.js so it can carry a nonce (Next.js App Router emits inline
// scripts that a static strict CSP would block). See middleware.js.
const nextConfig = {
  reactStrictMode: true,
  async headers() {
    return [{
      source: '/:path*',
      headers: [
        { key: 'X-Content-Type-Options', value: 'nosniff' },
        { key: 'X-Frame-Options', value: 'DENY' },
        { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
        { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
        { key: 'Permissions-Policy', value: 'geolocation=(), microphone=(), camera=()' },
      ],
    }];
  },
};

export default nextConfig;
