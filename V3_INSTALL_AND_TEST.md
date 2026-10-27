# BLACK MOON V3 — Individual Guest Admission

## Deployment order
1. **Back up Supabase** and keep the current live frontend unchanged.
2. Create a separate staging Supabase project or database backup to test this migration.
3. Run **only** `supabase/20261027_V3_INDIVIDUAL_ADMISSION.sql` AFTER the previous V2 migrations. Do not run `schema.sql`, `RESET_TEST_DATA.sql`, or prior upgrade files again.
4. Configure `.env.local` with staging VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY. Never include the service-role key in the frontend.
5. Run `npm ci`, `npm run build`, `npm run dev` locally. The build was **not** verified in the authoring environment: dependencies were incomplete. Fix any reported errors before deployment.
6. Test admin `#/admin` → ENTRY and gatekeeper `#/gate`. NOC search accepts `NOC-...`, QR scan still accepts the existing opaque entry token.
7. Test a confirmed four-person ticket: admit 2 with cash, scan again, admit 1 unpaid, record that guest's first payment separately, admit final guest, scan again. Ensure already-entered names cannot be admitted again.
8. Test two simultaneous staff sessions trying to admit the same person; only one should succeed.
9. Test bank transfer only after confirming actual receipt; verify admin corrections require a reason and gatekeepers cannot call `admin_correct_guest`.
10. Set full address and separate HTTPS Google Maps link in Admin → SETTINGS. Verify the ticket page link, printable PDF and downloaded PNG location QR.
11. Only after testing: deploy frontend and migration to production in a planned maintenance window.

## Legacy data — IMPORTANT
Old V2 tracked `amount_collected` and `checked_in_at` **per booking**, not per person.
V3 does not invent which people paid or entered. Bookings with any old payment/admission records are marked `v3_reconciled=false` and block new admission until an administrator assigns the historical statuses to the correct individual guests and finishes reconciliation.
The reconciliation button validates that individual paid totals equal the previous booking total, and that any booking previously marked checked in has all guests reviewed as entered. Administrator corrections are audited. Do not force `v3_reconciled=true` in SQL to bypass this safeguard.

## Roles
Gatekeepers can search NOC or scan QR, view individual states, admit not-yet-entered guests, and record first payments. They cannot change prior admission or payment records. Admins have an explicit EDIT button per guest, with mandatory reason and audit.
V2 whole-booking gate actions and legacy admin collection RPCs are disabled to avoid inconsistent totals.

## Known limitations / further review before production
- The new migration and UI were statically reviewed, but **no live Supabase integration test or complete Vite build was possible** in this environment.
- Dashboard check-in totals now use per-guest `entered_count` from the V3 `admin_bookings()` function. Validate the displayed count against guest records during staging tests.
- Confirm the venue's Google Maps link and ticket QR on both iOS and Android.
- Payment handling assumes the configured event price applies to each paid guest; bank transfers require explicit operator confirmation in the interface.
