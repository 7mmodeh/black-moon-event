# BLACK MOON — Bilingual Halloween Villa Update

## Install
1. Back up your project and Supabase data. Copy your existing `.env.local` into this project (do not publish it).
2. If not already applied, run the previous migrations in the order described in `INSTALL_FIRST.md`.
3. Run `supabase/20261027_international_mobile.sql` in Supabase SQL Editor. It validates new guest numbers in E.164 format.
4. `npm ci && npm run build && npm run dev`.
5. Test Arabic/English, the search-enabled country selector, all booking types, QR tickets, admin, payment states, and inquiries. Push to GitHub only after passing tests.

## Data reset
`supabase/RESET_TEST_DATA.sql` deletes ALL bookings, guests, notifications, and inquiries, but keeps admins and event settings. This is irreversible and intended only for prelaunch testing. **Never run it casually after accepting real bookings.**

## Notes
- Country selector contains 240 country/territory entries with international dialing codes; users can search by country name, ISO code, or dialing code. The input stores the full international number. Number syntax is validated, but carrier ownership is not verified by SMS.
- Inquiries follow the chosen website language. Admin replies are stored for internal review, not yet delivered to the guest in real time.
- The new villa artwork is a decorative cropped illustration; it is not a photograph of the actual venue.
- The current admin dashboard may still have English operational labels; these require a separate translation pass.
