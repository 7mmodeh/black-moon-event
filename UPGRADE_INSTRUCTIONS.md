# BLACK MOON — October 31 upgrade

## Event time
Saturday, October 31, 2026 at 03:00 Bahrain time (Friday night after midnight). This is early Halloween morning, **not after Saturday Halloween night**.

## Changes
- Cinematic red moon, animated ghosts/fog, mobile styles, reduced-motion support.
- Public choice of cash or bank transfer (method stored with each reservation).
- Admin overview, reservation status and payment filters, CSV export, bank-transfer verification.
- QR ticket SVG download; existing QR validation preserved.

## Required deployment sequence
1. **Back up your Supabase database** (especially bookings, guests, notifications, entry_audit).
2. Run `supabase/20261027_payment_methods.sql` in Supabase SQL Editor on the existing project. Do **not** rerun `schema.sql`.
3. Replace your local project source with this ZIP's `src`, `index.html`, and new migration file. Keep your existing `.env.local` private and your Git remote.
4. Run `npm install`, then `npm run build` locally; correct any build errors before deploying.
5. Test in a staging environment if possible, then push to GitHub/Cloudflare.
6. Test a new cash booking, a new transfer booking, transfer verification, entry scanning, complimentary booking, cancellation, and saved QR.

**Important:** Bank transfer verification is manual and requires admin confirmation. The system does not process or verify payments with a bank API. Transfer instructions are deliberately not invented or displayed; provide verified instructions separately. The old entry RPC and old booking RPC signatures are removed by the migration, so deploy the new frontend immediately after the SQL migration to avoid interrupting bookings.

**Security note:** A booking link contains a UUID and acts as a bearer link. Treat it as private. The downloaded QR contains an entry token; never publish it publicly.

**Validation status:** The source was edited but a complete Vite build could not be executed in this environment because package installation did not finish. Please run the local build before deploying.
