# BLACK MOON — Exact launch procedure

## Event information
- Saturday 31 October 2026, **2:00 AM Bahrain time** (Friday night into Saturday morning).
- 20 BHD per person, includes one drink and appetizer; additional food/drinks available.
- Cash or **admin-verified** bank transfer only; no cards.
- Confirmed reservation required for every guest.

## 1. Back up before changing anything
1. Make a copy of your existing GitHub-connected project folder.
2. Back up your Supabase database (including bookings, guests, inquiries, event settings and audit records).
3. Keep `.env.local` private. Do not upload it to GitHub or share service-role keys.

## 2. Install frontend in a NEW local folder
1. Extract this ZIP into `black-moon-final-test`.
2. Copy your existing `.env.local` into it.
3. Run `npm ci`, `npm run build`, then `npm run dev`.
4. Open the local Vite URL. Check Arabic/English switching, navigation, booking and admin.

## 3. Database migrations
**No new SQL migration is required for this release**: it changes presentation and on-page content only.
- Do not rerun `schema.sql` if the database already works.
- Do not rerun previous migration SQL without verifying it is missing.
- Never run `RESET_TEST_DATA.sql` as part of deployment. It deletes test/real booking data.
- Existing database functionality still depends on the previously applied payment, booking-type, venue and international-phone migrations.

## 4. Functional tests
- Public: both languages, instructions, FAQ, reserve button, inquiry submission.
- Booking: solo lady, ladies group, couple, group of couples; international phone validation; cash and bank transfer.
- Admin: approval/rejection, capacity, payment verification, venue address, inquiry inbox.
- Ticket: only confirmed bookings display QR; large centered QR, reference, venue details, PNG and print-to-PDF; verify QR scan.
- Door: four payment/entry states, no duplicate admission, no double cash collection.
- Mobile: test at least one iPhone and Android; test readability and touch targets.

## 5. Before real guests
1. Confirm venue address, directions, door staffing and emergency/safety arrangements.
2. Verify your capacity and reservation approval process.
3. Test a real transfer with your own bank details and admin verification.
4. Test guest QR entry from a second phone.
5. Clear **only test data** using the reset script after backup and before any real reservations.
6. Confirm event date/time in all existing Supabase settings, notifications, and external advertising.
7. Review the entire site for remaining English admin labels (admin localization is not complete in this release).

## 6. Deploy
1. Copy tested source into your GitHub-connected original project, preserving `.git` and `.env.local`.
2. Run `npm ci` and `npm run build` again.
3. Run `git status`, `git add .`, `git commit -m "BLACK MOON final branding instructions and FAQ"`, `git push origin main`.
4. Check Cloudflare Pages `black-moon-event` for a **new** successful commit deployment.
5. Open https://black-moon-event.pages.dev in a private browser window and recheck all flows.
6. Only then distribute the public reservation link and advertising QR.

## Important
- This package has no new database migrations. Existing SQL files are included for reference and **must not** all be run.
- The hero image is a promotional illustration, not a promise of a particular DJ, artist, crowd or venue.
- Saved PNG uses a branded canvas ticket; PDF uses browser print/save as PDF.
- The inquiry inbox still does not deliver a real-time chat conversation to guests.
