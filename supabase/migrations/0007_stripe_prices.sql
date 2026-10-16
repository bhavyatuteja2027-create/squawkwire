-- Squawkwire — Phase 4: map plans to Stripe price ids.
-- Create the prices in the Stripe dashboard (Test mode) for the Retail and Pro products,
-- then set them here (or via the Supabase dashboard). The checkout function reads
-- plans.provider_price_id. Re-run this with your real price ids.
--
-- Example (replace with your Test-mode price ids, they look like price_...):
--
--   update public.plans set provider_price_id = 'price_RETAIL_TEST' where code = 'retail';
--   update public.plans set provider_price_id = 'price_PRO_TEST'    where code = 'pro';
--
-- Leave this file as documentation; run the two UPDATEs with your actual ids.

-- No-op guard so the migration is safe to run as-is before you have price ids.
do $$ begin
  raise notice 'Set plans.provider_price_id for retail/pro with your Stripe Test price ids.';
end $$;
