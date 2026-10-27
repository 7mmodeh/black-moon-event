# BLACK MOON V2 — Staff role-based routing patch

This is a frontend-only update. No Supabase SQL migration is required, and no bookings or staff records are changed.

## Behavior
- After login on `#/admin`, a Gatekeeper is redirected to `#/gate`.
- After login on `#/gate`, an Administrator is redirected to `#/admin`.
- Logged-out staff remain on the page they selected to sign in.
- Authorization is checked through the existing `gate_my_access` RPC before rendering protected components.
- On a transient authorization error, a retry/sign-out screen is shown instead of silently denying access.
- Unassigned accounts remain restricted; Supabase security policies are unchanged.

## Install
1. Back up your existing project folder and `.env.local`.
2. Extract this ZIP to a new folder, copy your existing `.env.local` into it.
3. Run `npm ci` then `npm run build` locally.
4. Test Gatekeeper login via `#/admin` and Admin login via `#/gate` in separate private windows; verify correct redirection.
5. Test both staff roles' permissions and public reservations before pushing to GitHub.
6. Deploy frontend only after tests pass. Do not run SQL scripts for this update.

## Verification limitation
This environment could not complete `npm ci` (timed out), so the Vite production build has not been verified here.
