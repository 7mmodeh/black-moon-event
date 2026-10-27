-- Run AFTER 20261027_halloween_release.sql. Existing bookings are not modified.
-- Enforce international E.164 format for every NEW guest, regardless of frontend.
CREATE OR REPLACE FUNCTION public.validate_guests(p_guests jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n integer; g jsonb;
BEGIN
 IF jsonb_typeof(p_guests) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Guest list must be an array'; END IF;
 n := jsonb_array_length(p_guests);
 IF n < 1 OR n > 200 THEN RAISE EXCEPTION 'Guest count must be 1–200'; END IF;
 FOR g IN SELECT value FROM jsonb_array_elements(p_guests) LOOP
  IF length(trim(coalesce(g->>'name',''))) NOT BETWEEN 2 AND 100
     OR coalesce(g->>'phone','') !~ '^\+[1-9][0-9]{6,14}$' THEN
    RAISE EXCEPTION 'Each guest needs a name and a mobile number with international calling code (e.g. +973...)';
  END IF;
 END LOOP;
 RETURN n;
END $$;
