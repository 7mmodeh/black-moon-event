BLACK MOON HALLOWEEN RELEASE — October 31, 2026 at 02:00 Bahrain time

IMPORTANT: THIS RELEASE HAS NOT PASSED AN AUTOMATED VITE BUILD. DO NOT REPLACE YOUR LIVE SITE UNTIL YOU TEST LOCALLY.

1. Back up your existing project and Supabase database.
2. Copy this entire folder into a NEW local project folder (do not overwrite your live project yet).
3. Copy only your own existing .env.local into this new folder. Never commit it.
4. In Supabase SQL Editor, run supabase/20261027_halloween_release.sql ONLY IF your earlier schema, capacity and payment-method migrations were already applied. The new frontend requires this migration.
5. Run npm ci, then npm run build, then npm run dev. If build fails, do not deploy; share the error.
6. Test solo lady (1), ladies group (3), couple (2), group of couples (4); test cash and transfer, approval, admin and ticket.
7. In admin > CAPACITY/SETTINGS, set the full venue address and entry instructions.
8. Test inquiries in the floating chat, and read them in Admin > INQUIRIES. Admin replies are currently stored in the admin inbox only; outbound guest messaging is NOT implemented. Automated FAQ answers are displayed in the chat window.
9. Test the ticket PNG download and print layout on mobile and desktop.
10. Only after all tests pass, push to GitHub to deploy Cloudflare Pages.

Important limitations:
- No real-time push notification or return-message delivery to guests yet.
- The public ticket link remains the existing UUID-based link. Treat it as private.
- Do not promise an automatic bank transfer verification; staff must verify manually.
- Any reservation that was pending approval remains pending until staff approves it.
