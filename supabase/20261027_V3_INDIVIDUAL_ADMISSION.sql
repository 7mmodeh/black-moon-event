
-- BLACK MOON V3 — run AFTER V2 migrations. Back up production first.
-- Preserves bookings, guests, admin accounts, and all existing audit history.
BEGIN;
ALTER TABLE public.guests ADD COLUMN IF NOT EXISTS entered_at timestamptz;
ALTER TABLE public.guests ADD COLUMN IF NOT EXISTS paid_at timestamptz;
ALTER TABLE public.guests ADD COLUMN IF NOT EXISTS paid_amount numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.guests ADD COLUMN IF NOT EXISTS payment_method text;
ALTER TABLE public.guests ADD COLUMN IF NOT EXISTS admitted_by uuid REFERENCES auth.users(id);
ALTER TABLE public.guests ADD COLUMN IF NOT EXISTS payment_recorded_by uuid REFERENCES auth.users(id);
ALTER TABLE public.event_config ADD COLUMN IF NOT EXISTS maps_url text NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS public.guest_action_audit(
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 booking_id uuid NOT NULL REFERENCES public.bookings(id),
 guest_id uuid NOT NULL REFERENCES public.guests(id),
 actor uuid NOT NULL REFERENCES auth.users(id),
 action text NOT NULL CHECK(action IN ('admit','payment','admin_correction','legacy_import')),
 old_state jsonb NOT NULL,
 new_state jsonb NOT NULL,
 reason text,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.guest_action_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.guest_action_audit FROM PUBLIC,anon,authenticated;

-- Legacy aggregate records cannot reliably be attributed to individual guests.
-- Preserve them as historical aggregate values and mark the booking as needing
-- administrator reconciliation. Do NOT silently assign paid/entered to people.
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS v3_reconciled boolean NOT NULL DEFAULT true;
UPDATE public.bookings SET v3_reconciled=false
WHERE checked_in_at IS NOT NULL OR amount_collected>0;
-- Bookings with legacy paid/entry totals require an explicit admin reconciliation.

CREATE OR REPLACE FUNCTION public.gate_lookup_entry(p_token text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.bookings%rowtype; gs jsonb; rate numeric;
BEGIN
 IF NOT(public.is_admin() OR public.is_gatekeeper()) THEN RAISE EXCEPTION 'Access denied'; END IF;
 IF length(trim(coalesce(p_token,''))) NOT BETWEEN 3 AND 150 THEN RAISE EXCEPTION 'Invalid ticket number'; END IF;
 SELECT * INTO b FROM public.bookings
 WHERE upper(reference)=upper(trim(p_token))
 OR entry_token::text=trim(p_token)
 ORDER BY CASE WHEN upper(reference)=upper(trim(p_token)) THEN 0 ELSE 1 END LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT price_per_guest INTO rate FROM public.event_config WHERE id=1;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',g.id,'full_name',g.full_name,'phone',g.phone,
  'entered_at',g.entered_at,'paid_at',g.paid_at,'paid_amount',g.paid_amount,
  'payment_method',g.payment_method,'admitted_by',g.admitted_by,
  'payment_recorded_by',g.payment_recorded_by) ORDER BY g.full_name,g.id),'[]'::jsonb)
 INTO gs FROM public.guests g WHERE g.booking_id=b.id;
 RETURN jsonb_build_object('reference',b.reference,'status',b.status,'guest_count',b.guest_count,
  'complimentary',b.complimentary,'amount_due',b.amount_due,
  'amount_collected',b.amount_collected,'payment_method',b.payment_method,
  'checked_in_at',b.checked_in_at,'price_per_guest',rate,
  'v3_reconciled',b.v3_reconciled,'guests',gs);
END $$;

-- The only Gatekeeper write API. Each guest may be admitted once and paid once.
-- A later first-time payment is allowed, but an existing payment cannot be overwritten.
CREATE OR REPLACE FUNCTION public.gate_process_guests(
 p_token text,p_guest_ids uuid[],p_admit boolean,p_payment text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.bookings%rowtype; g public.guests%rowtype; rate numeric;
 n int; changed int:=0; before_state jsonb; after_state jsonb;
BEGIN
 IF NOT(public.is_admin() OR public.is_gatekeeper()) THEN RAISE EXCEPTION 'Access denied'; END IF;
 IF p_payment NOT IN ('none','cash','transfer') OR p_payment IS NULL THEN RAISE EXCEPTION 'Invalid payment choice'; END IF;
 IF NOT p_admit AND p_payment='none' THEN RAISE EXCEPTION 'No action selected'; END IF;
 n:=coalesce(array_length(p_guest_ids,1),0);
 IF n<1 OR n>200 OR (SELECT count(DISTINCT x) FROM unnest(p_guest_ids) x)<>n THEN
  RAISE EXCEPTION 'Select distinct guest names'; END IF;
 SELECT * INTO b FROM public.bookings WHERE upper(reference)=upper(trim(p_token))
  OR entry_token::text=trim(p_token) FOR UPDATE;
 IF NOT FOUND OR b.status<>'confirmed' THEN RAISE EXCEPTION 'Ticket not confirmed'; END IF;
 IF NOT b.v3_reconciled THEN RAISE EXCEPTION 'Legacy admission/payment records require administrator reconciliation'; END IF;
 SELECT price_per_guest INTO rate FROM public.event_config WHERE id=1;
 -- Lock every selected guest in a stable order to avoid concurrent double processing.
 IF (SELECT count(*) FROM (SELECT id FROM public.guests WHERE booking_id=b.id
    AND id=ANY(p_guest_ids) ORDER BY id FOR UPDATE) locked)<>n THEN
  RAISE EXCEPTION 'Guest selection does not match this ticket'; END IF;
 FOR g IN SELECT * FROM public.guests WHERE booking_id=b.id AND id=ANY(p_guest_ids) ORDER BY id LOOP
  IF p_admit AND g.entered_at IS NOT NULL THEN RAISE EXCEPTION 'Guest % already admitted',g.full_name; END IF;
  IF p_payment<>'none' AND (g.paid_at IS NOT NULL OR g.paid_amount>0) THEN RAISE EXCEPTION 'Payment already recorded for %',g.full_name; END IF;
  IF p_payment='transfer' AND NOT b.complimentary AND b.payment_method<>'transfer' THEN
   RAISE EXCEPTION 'Bank transfer not selected for this booking'; END IF;
 END LOOP;
 FOR g IN SELECT * FROM public.guests WHERE booking_id=b.id AND id=ANY(p_guest_ids) ORDER BY id LOOP
  before_state:=jsonb_build_object('entered_at',g.entered_at,'paid_at',g.paid_at,'paid_amount',g.paid_amount,'payment_method',g.payment_method);
  UPDATE public.guests SET
   entered_at=CASE WHEN p_admit THEN now() ELSE entered_at END,
   admitted_by=CASE WHEN p_admit THEN auth.uid() ELSE admitted_by END,
   paid_at=CASE WHEN p_payment<>'none' OR b.complimentary THEN now() ELSE paid_at END,
   paid_amount=CASE WHEN b.complimentary THEN 0 WHEN p_payment<>'none' THEN rate ELSE paid_amount END,
   payment_method=CASE WHEN b.complimentary THEN 'complimentary' WHEN p_payment<>'none' THEN p_payment ELSE payment_method END,
   payment_recorded_by=CASE WHEN p_payment<>'none' OR b.complimentary THEN auth.uid() ELSE payment_recorded_by END
   WHERE id=g.id;
  SELECT jsonb_build_object('entered_at',entered_at,'paid_at',paid_at,'paid_amount',paid_amount,'payment_method',payment_method)
   INTO after_state FROM public.guests WHERE id=g.id;
  INSERT INTO public.guest_action_audit(booking_id,guest_id,actor,action,old_state,new_state)
   VALUES(b.id,g.id,auth.uid(),CASE WHEN p_admit THEN 'admit' ELSE 'payment' END,before_state,after_state);
  changed:=changed+1;
 END LOOP;
 UPDATE public.bookings SET
  amount_collected=(SELECT coalesce(sum(paid_amount),0) FROM public.guests WHERE booking_id=b.id),
  checked_in_at=(SELECT min(entered_at) FROM public.guests WHERE booking_id=b.id)
 WHERE id=b.id;
 RETURN jsonb_build_object('processed',changed,'reference',b.reference);
END $$;

CREATE OR REPLACE FUNCTION public.admin_correct_guest(
 p_guest_id uuid,p_entered boolean,p_paid boolean,p_method text,p_reason text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g public.guests%rowtype; b public.bookings%rowtype; rate numeric; old_state jsonb; new_state jsonb;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
 IF length(trim(coalesce(p_reason,'')))<8 THEN RAISE EXCEPTION 'Correction reason must contain at least 8 characters'; END IF;
 IF p_method NOT IN ('cash','transfer','complimentary','none') THEN RAISE EXCEPTION 'Invalid payment method'; END IF;
 SELECT * INTO g FROM public.guests WHERE id=p_guest_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Guest not found'; END IF;
 SELECT * INTO b FROM public.bookings WHERE id=g.booking_id FOR UPDATE;
 SELECT price_per_guest INTO rate FROM public.event_config WHERE id=1;
 IF p_paid AND NOT b.complimentary AND p_method='none' THEN RAISE EXCEPTION 'Payment method required'; END IF;
 old_state:=jsonb_build_object('entered_at',g.entered_at,'paid_at',g.paid_at,'paid_amount',g.paid_amount,'payment_method',g.payment_method);
 UPDATE public.guests SET
  entered_at=CASE WHEN p_entered THEN coalesce(entered_at,now()) ELSE NULL END,
  admitted_by=CASE WHEN p_entered THEN coalesce(admitted_by,auth.uid()) ELSE NULL END,
  paid_at=CASE WHEN p_paid THEN coalesce(paid_at,now()) ELSE NULL END,
  paid_amount=CASE WHEN p_paid AND NOT b.complimentary THEN rate ELSE 0 END,
  payment_method=CASE WHEN p_paid THEN CASE WHEN b.complimentary THEN 'complimentary' ELSE p_method END ELSE NULL END,
  payment_recorded_by=CASE WHEN p_paid THEN auth.uid() ELSE NULL END WHERE id=g.id;
 SELECT jsonb_build_object('entered_at',entered_at,'paid_at',paid_at,'paid_amount',paid_amount,'payment_method',payment_method)
 INTO new_state FROM public.guests WHERE id=g.id;
 INSERT INTO public.guest_action_audit(booking_id,guest_id,actor,action,old_state,new_state,reason)
 VALUES(b.id,g.id,auth.uid(),'admin_correction',old_state,new_state,trim(p_reason));
 IF b.v3_reconciled THEN
  UPDATE public.bookings SET
   amount_collected=(SELECT coalesce(sum(paid_amount),0) FROM public.guests WHERE booking_id=b.id),
   checked_in_at=(SELECT min(entered_at) FROM public.guests WHERE booking_id=b.id) WHERE id=b.id;
 END IF;
END $$;

-- Admin reconciliation of legacy aggregate values is explicit and audited per guest.
-- Administrator reviews the existing booking and selects each guest's actual state.
CREATE OR REPLACE FUNCTION public.admin_finish_guest_reconciliation(p_token text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.bookings%rowtype;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'Administrator only'; END IF;
 SELECT * INTO b FROM public.bookings WHERE upper(reference)=upper(trim(p_token)) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;
 IF b.amount_collected<>(SELECT coalesce(sum(paid_amount),0) FROM public.guests WHERE booking_id=b.id)
 THEN RAISE EXCEPTION 'Reconcile individual payments to match legacy collected total before finishing'; END IF;
 IF b.checked_in_at IS NOT NULL AND EXISTS(SELECT 1 FROM public.guests WHERE booking_id=b.id AND entered_at IS NULL)
 THEN RAISE EXCEPTION 'Legacy booking was marked entered: review and mark all actually entered guests before finishing'; END IF;
 UPDATE public.bookings SET v3_reconciled=true,
 amount_collected=(SELECT coalesce(sum(paid_amount),0) FROM public.guests WHERE booking_id=b.id),
 checked_in_at=(SELECT min(entered_at) FROM public.guests WHERE booking_id=b.id) WHERE id=b.id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_bookings() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'Access denied'; END IF;
 SELECT coalesce(jsonb_agg(x ORDER BY x.created_at DESC),'[]'::jsonb) INTO result
 FROM (SELECT b.*,
   coalesce((SELECT string_agg(g.full_name,', ' ORDER BY g.full_name) FROM public.guests g WHERE g.booking_id=b.id),'') guest_names,
   (SELECT count(*) FROM public.guests g WHERE g.booking_id=b.id AND g.entered_at IS NOT NULL) AS entered_count,
   (SELECT count(*) FROM public.guests g WHERE g.booking_id=b.id AND g.paid_at IS NOT NULL) AS paid_count
  FROM public.bookings b) x;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.admin_event_details() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'Access denied'; END IF;
 SELECT jsonb_build_object('venue_address',venue_address,'maps_url',maps_url,
 'entry_instructions',entry_instructions,'public_area',public_area)
 INTO result FROM public.event_config WHERE id=1;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.admin_save_event_details_v3(
 p_address text,p_maps_url text,p_instructions text,p_area text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'Access denied'; END IF;
 IF length(coalesce(p_address,''))>1500 OR length(coalesce(p_instructions,''))>2000
 OR length(coalesce(p_area,''))>150 OR length(coalesce(p_maps_url,''))>2048 THEN RAISE EXCEPTION 'Field too long'; END IF;
 IF coalesce(trim(p_maps_url),'')<>'' AND NOT (
  trim(p_maps_url) ~* '^https://(maps\.app\.goo\.gl|maps\.google\.[a-z.]+|www\.google\.[a-z.]+|google\.[a-z.]+|goo\.gl/maps)/'
 ) THEN RAISE EXCEPTION 'Use a valid HTTPS Google Maps link'; END IF;
 UPDATE public.event_config SET venue_address=coalesce(p_address,''),
 maps_url=coalesce(trim(p_maps_url),''),entry_instructions=coalesce(p_instructions,''),
 public_area=coalesce(p_area,'Bahrain') WHERE id=1;
END $$;

CREATE OR REPLACE FUNCTION public.get_ticket(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.bookings%rowtype;c public.event_config%rowtype;
BEGIN
 SELECT * INTO b FROM public.bookings WHERE id=p_id;
 IF NOT FOUND THEN RETURN null; END IF;
 SELECT * INTO c FROM public.event_config WHERE id=1;
 RETURN jsonb_build_object('reference',b.reference,'status',b.status,'guest_count',b.guest_count,
 'amount_due',b.amount_due,'payment_method',b.payment_method,
 'venue_address',CASE WHEN b.status='confirmed' THEN c.venue_address ELSE null END,
 'maps_url',CASE WHEN b.status='confirmed' THEN c.maps_url ELSE null END,
 'entry_instructions',CASE WHEN b.status='confirmed' THEN c.entry_instructions ELSE null END,
 'entry_token',CASE WHEN b.status='confirmed' THEN b.entry_token::text ELSE null END);
END $$;

-- Disable legacy whole-booking mutation paths for gatekeepers.
-- Admin can still call these, but they are disabled to prevent inconsistent V3 per-guest totals.
CREATE OR REPLACE FUNCTION public.gate_record_entry(
 p_token text,p_payment text,p_entry text,p_allow_correction boolean DEFAULT false
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 RAISE EXCEPTION 'Legacy whole-ticket entry disabled. Use individual guest admission.';
END $$;
CREATE OR REPLACE FUNCTION public.gate_verify_transfer(p_token text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 RAISE EXCEPTION 'Legacy whole-ticket transfer verification disabled. Use individual guest payment.';
END $$;
CREATE OR REPLACE FUNCTION public.admin_checkin(p_token text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 RAISE EXCEPTION 'Legacy whole-ticket check-in disabled. Use individual guest admission.';
END $$;
CREATE OR REPLACE FUNCTION public.admin_verify_transfer(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 RAISE EXCEPTION 'Whole-booking payment disabled. Record verified payment per guest.';
END $$;
CREATE OR REPLACE FUNCTION public.admin_update_booking(p_id uuid,p_action text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.bookings%rowtype; cfg public.event_config%rowtype; used int;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'Access denied'; END IF;
 IF p_action='collect' THEN RAISE EXCEPTION 'Use individual guest payments'; END IF;
 SELECT * INTO cfg FROM public.event_config WHERE id=1 FOR UPDATE;
 SELECT * INTO b FROM public.bookings WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;
 IF p_action='approve' THEN
  IF b.status<>'pending' THEN RAISE EXCEPTION 'Booking not pending'; END IF;
  SELECT coalesce(sum(guest_count),0) INTO used FROM public.bookings WHERE status='confirmed';
  IF used+b.guest_count>cfg.capacity THEN RAISE EXCEPTION 'Capacity exceeded'; END IF;
  UPDATE public.bookings SET status='confirmed' WHERE id=p_id;
 ELSIF p_action='reject' THEN
  IF b.status<>'pending' THEN RAISE EXCEPTION 'Booking not pending'; END IF;
  UPDATE public.bookings SET status='rejected' WHERE id=p_id;
 ELSIF p_action='cancel' THEN
  IF b.status<>'confirmed' OR b.checked_in_at IS NOT NULL
   OR EXISTS(SELECT 1 FROM public.guests WHERE booking_id=b.id AND entered_at IS NOT NULL)
  THEN RAISE EXCEPTION 'Cannot cancel booking with admissions'; END IF;
  UPDATE public.bookings SET status='cancelled' WHERE id=p_id;
 ELSE RAISE EXCEPTION 'Unknown action'; END IF;
 INSERT INTO public.notifications(title,message,booking_id)
 VALUES('Booking updated',b.reference||': '||p_action,b.id);
END $$;
REVOKE ALL ON FUNCTION public.gate_lookup_entry(text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.gate_process_guests(text,uuid[],boolean,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_correct_guest(uuid,boolean,boolean,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_finish_guest_reconciliation(text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_save_event_details_v3(text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gate_lookup_entry(text),public.gate_process_guests(text,uuid[],boolean,text),
 public.admin_correct_guest(uuid,boolean,boolean,text,text),public.admin_finish_guest_reconciliation(text),
 public.admin_save_event_details_v3(text,text,text,text) TO authenticated;
COMMIT;
