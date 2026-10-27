-- BLACK MOON: REUSABLE TEST-DATA RESET
-- DANGER: IRREVERSIBLY DELETES ALL BOOKINGS, GUESTS, PAYMENT/ENTRY AUDIT HISTORY, NOTIFICATIONS, AND INQUIRIES.
-- DO NOT RUN AFTER LIVE SALES BEGIN UNLESS YOU INTEND TO DELETE REAL GUEST DATA.
-- Does NOT remove admin accounts, event configuration, capacity, or venue address.
-- Run only in Supabase SQL Editor with project owner access, after taking a database backup.
BEGIN;
TRUNCATE TABLE public.entry_audit, public.notifications, public.guests, public.bookings, public.inquiries RESTART IDENTITY;
COMMIT;
-- Verify: SELECT (SELECT count(*) FROM public.bookings) AS bookings,
--                (SELECT count(*) FROM public.guests) AS guests,
--                (SELECT count(*) FROM public.inquiries) AS inquiries;
