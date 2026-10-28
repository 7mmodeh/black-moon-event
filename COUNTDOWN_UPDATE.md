# BLACK MOON — Live Homepage Countdown

Frontend-only update. No Supabase SQL or database change is needed.

- Displays a live days / hours / minutes / seconds countdown inside the homepage hero, before the reservation button.
- Target: Saturday 31 October 2026, 02:00 Bahrain time (UTC+03:00), equivalent to 2026-10-30T23:00:00Z.
- Arabic and English translations, mobile layout, reduced-motion handling.
- Uses the visitor clock, recalculates every second and when the tab regains focus.
- At zero, displays THE NIGHT HAS BEGUN / بدأت الليلة; existing reservation logic is unaffected.
- No countdown in the admin or gatekeeper interfaces.

## Install

1. Extract this ZIP into a **new folder** (not over your live deployment).
2. Copy your current `.env.local` into that folder yourself. Credentials are intentionally excluded from this ZIP.
3. Run `npm ci`, then `npm run build`, then `npm run dev`.
4. Check `#/` in Arabic and English on desktop and mobile. Confirm the reservation button still works.
5. Deploy to Cloudflare Pages only after local verification and your approval.

Build note: The dependency installation in the authoring environment timed out, so a complete production build has not been verified here.
