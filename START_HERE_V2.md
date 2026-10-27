# BLACK MOON V2 — Operations Release

## Scope
- Fixes the **Bookings / Manage Reservations / Add House Guests** black screen caused by missing `statusFilter` and `paymentFilter` React state.
- Adds a page error boundary so future rendering errors show a diagnostic instead of an empty page.
- Adds dedicated `#/gate` Gatekeeper login, mobile QR scanner, manual token/reference lookup, and all four independent payment/admission combinations.
- Allows staff to verify actual bank transfers at the entrance, with explicit confirmation.
- Logs entry actions, corrections and transfer verification in `gatekeeper_audit`; the admin gets an Activity Log tab.
- Updates the downloaded PNG ticket to a larger centered QR with BLACK MOON branding, date, reference, guest count, payment info and venue address; removes duplicated bilingual instructions from the ticket page.
- Allows one or more complimentary house guests instead of requiring even numbers.

## Critical: do not run all SQL files
Only **one new SQL migration** is needed if your existing BLACK MOON database already has the earlier payment method, entry-capacity, Halloween and international-phone migrations installed:

`supabase/20261027_GATEKEEPER_V2.sql`

Do NOT rerun `schema.sql` or `RESET_TEST_DATA.sql`. Do NOT run the migration until you have a database backup and tested the existing database compatibility.

## Safe installation — exact order

1. **Backup** your current local project and export/backup the Supabase database. Preserve `.env.local` (never publish secrets).
2. **Stage frontend:** extract this ZIP into a NEW directory. Copy `.env.local` from the working project into that directory.
3. Open PowerShell in the new directory and run:
   ```powershell
   npm ci
   npm run build
   npm run dev
   ```
   Stop if the build fails. Do not push to the live branch.
4. **Stage database first if possible:** use a separate Supabase staging project with a copy of your schema and anonymized test data. Apply the one new migration above. Do not apply a schema to a production project that you have not backed up.
5. In Supabase Dashboard > Authentication > Users, **create a separate gatekeeper user** with a unique email/password. Copy the user's UUID. Then run in SQL Editor:
   ```sql
   INSERT INTO public.gatekeeper_users(user_id)
   VALUES ('REPLACE_WITH_GATEKEEPER_AUTH_UUID'::uuid)
   ON CONFLICT (user_id) DO NOTHING;
   ```
   **Never** add this gatekeeper to `public.admin_users`. If already there, remove that admin membership after confirming it is the correct gatekeeper account.
6. Open `http://localhost:5173/#/gate` (or the port Vite displays) and sign in with the gatekeeper account. The gatekeeper must NOT access `#/admin` or any admin RPC.
7. Test these four independent combinations on disposable bookings: paid + entered; unpaid + not entered; unpaid + entered; paid + not entered. Test cash, transfer verification, repeat scans, corrections, cancelled tickets, and complimentary bookings.
8. Log in as admin and test **Bookings**, **Manage Reservations**, **Add House Guests**, **Activity Log**, CSV export, capacity, inquiry inbox and event settings. Verify no black screens.
9. Generate a confirmed ticket, download its PNG and use Print > Save as PDF. Check the full QR scans, the correct date (Saturday 31 October 2026, 02:00 Bahrain time), reference and current venue address. Confirm no repeated instructions.
10. Test on mobile Safari/Chrome with camera permissions and the Arabic and English language modes.
11. **Production deployment:** when all checks pass, apply the new SQL migration to your backed-up production Supabase project, create gatekeeper user and membership there, then copy the tested frontend into the existing GitHub-connected repository (preserve `.git` and `.env.local`).
12. Run `npm ci`, `npm run build`, then:
   ```powershell
   git add .
   git commit -m "BLACK MOON V2 gatekeeper and operations fixes"
   git push origin main
   ```
13. In Cloudflare Pages confirm the deployment commit succeeded. Open `https://black-moon-event.pages.dev` and repeat the smoke tests. Confirm the existing `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` values are configured in Cloudflare Pages. Never expose a service-role key.

## Gatekeeper permissions
Allowed: sign in to `#/gate`, scan/search QR/reference, view only necessary guest and payment details for the scanned ticket, mark paid/unpaid and entered/not entered, collect cash, verify actual bank transfer, record corrections. All actions are auditable.

Not allowed: `admin_bookings`, financial dashboard, all bookings list, capacity changes, complimentary creation, inquiries, event settings, staff management or Activity Log. These are restricted by Supabase RPC guards, not just by hiding the UI.

## Important payment note
Bank transfers must be **verified against actual bank receipt** before the booking is marked paid. Payment reversals and entry corrections require confirmation and leave an audit record. Reversing a previously verified transfer in the gate interface changes the recorded payment status; reconcile any real bank refund separately.

## Production build status
The source was syntax-checked using TypeScript's JSX transpiler. A complete Vite build could **not** be completed in the generation environment because dependency installation timed out. A successful `npm run build` on your machine is mandatory before deployment.

## Rollback
If the frontend misbehaves, roll back to the previous Cloudflare Pages deployment and restore the previous source commit. The new SQL migration is additive; do not drop new tables or functions as a rollback without reviewing data and audit logs. Never run the reset SQL as a rollback.
