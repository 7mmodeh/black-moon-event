-- BLACK MOON V2: additive Gatekeeper permissions and audited entrance operations.
-- Apply ONCE after all earlier BLACK MOON migrations. No booking records are deleted.
BEGIN;
CREATE TABLE IF NOT EXISTS public.gatekeeper_users (
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.gatekeeper_users ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gatekeeper_users FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.gatekeeper_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 booking_id uuid NOT NULL REFERENCES public.bookings(id),
 actor uuid NOT NULL REFERENCES auth.users(id),
 action text NOT NULL CHECK(action IN ('entry_record','transfer_verified')),
 old_amount numeric(10,2), new_amount numeric(10,2),
 old_entered_at timestamptz, new_entered_at timestamptz,
 method text, note text,
 recorded_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.gatekeeper_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gatekeeper_audit FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.is_gatekeeper() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT EXISTS(SELECT 1 FROM public.gatekeeper_users WHERE user_id = auth.uid())
$$;
REVOKE ALL ON FUNCTION public.is_gatekeeper() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_gatekeeper() TO authenticated;

CREATE OR REPLACE FUNCTION public.gate_my_access() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 RETURN jsonb_build_object('allowed',public.is_admin() OR public.is_gatekeeper(),
  'role', CASE WHEN public.is_admin() THEN 'admin' WHEN public.is_gatekeeper() THEN 'gatekeeper' ELSE 'none' END);
END $$;
REVOKE ALL ON FUNCTION public.gate_my_access() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gate_my_access() TO authenticated;

-- Search is restricted to authorized staff and only returns fields needed at the gate.
CREATE OR REPLACE FUNCTION public.gate_lookup_entry(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings%rowtype; gs jsonb;
BEGIN
 IF NOT (public.is_admin() OR public.is_gatekeeper()) THEN RAISE EXCEPTION 'Access denied'; END IF;
 IF length(trim(coalesce(p_token,''))) NOT BETWEEN 3 AND 100 THEN RAISE EXCEPTION 'Invalid ticket token'; END IF;
 SELECT * INTO b FROM public.bookings
 WHERE entry_token::text=trim(p_token) OR upper(reference)=upper(trim(p_token));
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',g.id,'full_name',g.full_name,'phone',g.phone)
  ORDER BY g.full_name),'[]'::jsonb) INTO gs FROM public.guests g WHERE g.booking_id=b.id;
 RETURN jsonb_build_object('reference',b.reference,'status',b.status,'guest_count',b.guest_count,
  'complimentary',b.complimentary,'amount_due',b.amount_due,'amount_collected',b.amount_collected,
  'payment_method',b.payment_method,'checked_in_at',b.checked_in_at,'guests',gs);
END $$;
REVOKE ALL ON FUNCTION public.gate_lookup_entry(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gate_lookup_entry(text) TO authenticated;

-- Gatekeepers can explicitly verify bank transfers. The action is audited.
CREATE OR REPLACE FUNCTION public.gate_verify_transfer(p_token text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings%rowtype;
BEGIN
 IF NOT (public.is_admin() OR public.is_gatekeeper()) THEN RAISE EXCEPTION 'Access denied'; END IF;
 SELECT * INTO b FROM public.bookings
 WHERE entry_token::text=trim(p_token) OR upper(reference)=upper(trim(p_token)) FOR UPDATE;
 IF NOT FOUND OR b.status<>'confirmed' OR b.complimentary OR b.payment_method<>'transfer' THEN
  RAISE EXCEPTION 'Not an eligible confirmed bank transfer'; END IF;
 IF b.amount_collected>=b.amount_due THEN RAISE EXCEPTION 'Already recorded as paid'; END IF;
 UPDATE public.bookings SET amount_collected=amount_due WHERE id=b.id;
 INSERT INTO public.gatekeeper_audit(booking_id,actor,action,old_amount,new_amount,old_entered_at,new_entered_at,method,note)
 VALUES(b.id,auth.uid(),'transfer_verified',b.amount_collected,b.amount_due,b.checked_in_at,b.checked_in_at,'transfer','Staff verified actual bank receipt');
 INSERT INTO public.notifications(title,message,booking_id) VALUES('Bank transfer verified',b.reference||' by entrance staff',b.id);
END $$;
REVOKE ALL ON FUNCTION public.gate_verify_transfer(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gate_verify_transfer(text) TO authenticated;

-- Independent payment/entry flags, with logged corrections and concurrency protection.
CREATE OR REPLACE FUNCTION public.gate_record_entry(
 p_token text,p_payment text,p_entry text,p_allow_correction boolean DEFAULT false
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bookings%rowtype; next_amount numeric(10,2); next_entered timestamptz;
BEGIN
 IF NOT (public.is_admin() OR public.is_gatekeeper()) THEN RAISE EXCEPTION 'Access denied'; END IF;
 IF p_payment NOT IN ('paid','unpaid') OR p_entry NOT IN ('entered','not_entered') THEN
  RAISE EXCEPTION 'Invalid entry/payment status'; END IF;
 SELECT * INTO b FROM public.bookings
 WHERE entry_token::text=trim(p_token) OR upper(reference)=upper(trim(p_token)) FOR UPDATE;
 IF NOT FOUND OR b.status<>'confirmed' THEN RAISE EXCEPTION 'Invalid or unconfirmed ticket'; END IF;
 IF b.checked_in_at IS NOT NULL AND NOT p_allow_correction THEN
  RAISE EXCEPTION 'Already admitted. Explicit correction confirmation is required'; END IF;
 IF NOT b.complimentary AND p_payment='paid' AND b.payment_method='transfer'
  AND b.amount_collected<b.amount_due THEN
  RAISE EXCEPTION 'Verify the bank transfer before recording paid'; END IF;
 IF NOT b.complimentary AND p_payment='unpaid' AND b.amount_collected>0 AND NOT p_allow_correction THEN
  RAISE EXCEPTION 'Reversing an existing payment requires explicit correction confirmation'; END IF;
 next_amount:=CASE WHEN b.complimentary THEN 0 WHEN p_payment='paid' THEN b.amount_due ELSE 0 END;
 next_entered:=CASE WHEN p_entry='entered' THEN coalesce(b.checked_in_at,now()) ELSE NULL END;
 UPDATE public.bookings SET amount_collected=next_amount,checked_in_at=next_entered WHERE id=b.id;
 INSERT INTO public.gatekeeper_audit(booking_id,actor,action,old_amount,new_amount,old_entered_at,new_entered_at,method,note)
 VALUES(b.id,auth.uid(),'entry_record',b.amount_collected,next_amount,b.checked_in_at,next_entered,b.payment_method,
 CASE WHEN p_allow_correction THEN 'Staff-confirmed correction' ELSE 'Initial gate action' END);
 INSERT INTO public.entry_audit(booking_id,actor,payment_choice,entry_choice,amount_before,amount_after)
 VALUES(b.id,auth.uid(),p_payment,p_entry,b.amount_collected,next_amount);
 INSERT INTO public.notifications(title,message,booking_id)
 VALUES('Gate entry record',b.reference||': '||p_payment||', '||p_entry,b.id);
END $$;
REVOKE ALL ON FUNCTION public.gate_record_entry(text,text,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gate_record_entry(text,text,text,boolean) TO authenticated;

-- Admin-only view of entrance actions and corrections (gatekeepers cannot call this).
CREATE OR REPLACE FUNCTION public.admin_gate_audit() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
 IF NOT public.is_admin() THEN RAISE EXCEPTION 'Access denied'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.recorded_at DESC),'[]'::jsonb) INTO result
 FROM (SELECT ga.id,ga.recorded_at,ga.action,ga.actor,ga.old_amount,ga.new_amount,
  ga.old_entered_at,ga.new_entered_at,ga.method,ga.note,b.reference
  FROM public.gatekeeper_audit ga JOIN public.bookings b ON b.id=ga.booking_id
  ORDER BY ga.recorded_at DESC LIMIT 300) a;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.admin_gate_audit() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_gate_audit() TO authenticated;

COMMIT;

-- AFTER applying migration and creating the gatekeeper in Supabase Auth > Users:
-- INSERT INTO public.gatekeeper_users(user_id) VALUES ('REPLACE_WITH_AUTH_USER_UUID') ON CONFLICT DO NOTHING;
-- Do not insert into admin_users for gatekeeper accounts.
