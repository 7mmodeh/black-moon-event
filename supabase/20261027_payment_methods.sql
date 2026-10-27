-- BLACK MOON payment-method upgrade. Run once in Supabase SQL Editor.
-- Preserves existing reservations; defaults existing paid bookings to cash.
alter table public.bookings add column if not exists payment_method text not null default 'cash' check (payment_method in ('cash','transfer'));

-- Replace the existing public booking RPC (same return contract) with an additional optional payment preference.
-- Drop old signature only after creating the new signature, to avoid ambiguity with default arguments.
create or replace function public.create_public_booking(p_guests jsonb,p_email text,p_payment_method text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n int;b public.bookings%rowtype;g jsonb;cfg public.event_config%rowtype;
begin
 n:=public.validate_guests(p_guests);
 if length(coalesce(p_email,''))>254 then raise exception 'Email too long';end if;
 if p_payment_method not in ('cash','transfer') then raise exception 'Invalid payment method';end if;
 select * into cfg from public.event_config where id=1;
 if not cfg.booking_open then raise exception 'Reservations are closed';end if;
 insert into public.bookings(guest_count,email,amount_due,payment_method)
 values(n,nullif(trim(p_email),''),n*cfg.price_per_guest,p_payment_method) returning * into b;
 for g in select value from jsonb_array_elements(p_guests) loop
  insert into public.guests(booking_id,full_name,phone) values(b.id,trim(g->>'name'),trim(g->>'phone'));
 end loop;
 insert into public.notifications(title,message,booking_id)
 values('New reservation',b.reference||' requests '||n||' guests; payment: '||p_payment_method,b.id);
 return jsonb_build_object('id',b.id,'reference',b.reference);
end $$;
revoke all on function public.create_public_booking(jsonb,text,text) from public;
grant execute on function public.create_public_booking(jsonb,text,text) to anon,authenticated;
drop function if exists public.create_public_booking(jsonb,text);

-- Ticket view includes preference but never exposes bank details.
create or replace function public.get_ticket(p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b public.bookings%rowtype;
begin
 select * into b from public.bookings where id=p_id;
 if not found then return null;end if;
 return jsonb_build_object('reference',b.reference,'status',b.status,'guest_count',b.guest_count,
 'amount_due',b.amount_due,'payment_method',b.payment_method,
 'entry_token',case when b.status='confirmed' then b.entry_token::text else null end);
end $$;

-- Staff-only verification of a transfer actually received. Audit and notify.
create or replace function public.admin_verify_transfer(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare b public.bookings%rowtype;
begin
 if not public.is_admin() then raise exception 'Access denied';end if;
 select * into b from public.bookings where id=p_id for update;
 if not found or b.status<>'confirmed' or b.complimentary or b.payment_method<>'transfer' then
  raise exception 'Not an eligible confirmed transfer booking';end if;
 if b.amount_collected>=b.amount_due then raise exception 'Already paid';end if;
 update public.bookings set amount_collected=amount_due where id=p_id;
 insert into public.notifications(title,message,booking_id) values('Transfer verified',b.reference||': bank transfer confirmed by staff',p_id);
end $$;
revoke all on function public.admin_verify_transfer(uuid) from public,anon;
grant execute on function public.admin_verify_transfer(uuid) to authenticated;

-- Entry status: preserve payment method and never overwrite a previously recorded payment.
create or replace function public.admin_lookup_entry(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b public.bookings%rowtype;gs jsonb;
begin
 if not public.is_admin() then raise exception 'Access denied';end if;
 select * into b from public.bookings where entry_token::text=p_token;
 if not found then return null;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'full_name',g.full_name,'phone',g.phone) order by g.full_name),'[]'::jsonb)
 into gs from public.guests g where g.booking_id=b.id;
 return jsonb_build_object('reference',b.reference,'status',b.status,'guest_count',b.guest_count,
 'complimentary',b.complimentary,'amount_due',b.amount_due,'amount_collected',b.amount_collected,
 'payment_method',b.payment_method,'checked_in_at',b.checked_in_at,'guests',gs);
end $$;

-- New 4-argument entry RPC; the old RPC is removed to prevent accidentally bypassing payment-method checks.
create or replace function public.admin_resolve_entry(p_token text,p_payment text,p_entry text,p_method text)
returns void language plpgsql security definer set search_path='' as $$
declare b public.bookings%rowtype;next_amount numeric(10,2);
begin
 if not public.is_admin() then raise exception 'Access denied';end if;
 if p_payment not in ('paid','unpaid') or p_entry not in ('entered','not_entered') then raise exception 'Invalid selection';end if;
 select * into b from public.bookings where entry_token::text=p_token for update;
 if not found or b.status<>'confirmed' then raise exception 'Ticket invalid or not confirmed';end if;
 if b.checked_in_at is not null then raise exception 'Ticket already checked in';end if;
 if p_payment='paid' and not b.complimentary and (p_method is null or p_method<>b.payment_method) then
  raise exception 'Payment method mismatch. Verify transfer in the bookings dashboard or select the correct payment method';end if;
 if p_payment='paid' and b.payment_method='transfer' and b.amount_collected<b.amount_due then
  raise exception 'Bank transfer must be verified in Reservations before marking paid';end if;
 next_amount:=case when b.complimentary then 0 when p_payment='paid' then b.amount_due else b.amount_collected end;
 update public.bookings set amount_collected=next_amount,
 checked_in_at=case when p_entry='entered' then now() else null end where id=b.id;
 insert into public.entry_audit(booking_id,actor,payment_choice,entry_choice,amount_before,amount_after)
 values(b.id,auth.uid(),p_payment,p_entry,b.amount_collected,next_amount);
 insert into public.notifications(title,message,booking_id)
 values('Door record',b.reference||': '||p_payment||', '||p_entry,b.id);
end $$;
revoke all on function public.admin_resolve_entry(text,text,text,text) from public,anon;
grant execute on function public.admin_resolve_entry(text,text,text,text) to authenticated;
drop function if exists public.admin_resolve_entry(text,text,text);

-- Prevent the legacy collect action from misclassifying a bank transfer as cash.
create or replace function public.admin_update_booking(p_id uuid,p_action text) returns void
language plpgsql security definer set search_path='' as $$
declare b public.bookings%rowtype;cfg public.event_config%rowtype;used int;
begin
 if not public.is_admin() then raise exception 'Access denied';end if;
 select * into cfg from public.event_config where id=1 for update;
 select * into b from public.bookings where id=p_id for update;
 if not found then raise exception 'Booking not found';end if;
 if p_action='approve' then
  if b.status<>'pending' then raise exception 'Booking not pending';end if;
  select coalesce(sum(guest_count),0) into used from public.bookings where status='confirmed';
  if used+b.guest_count>cfg.capacity then raise exception 'Capacity exceeded';end if;
  update public.bookings set status='confirmed' where id=p_id;
 elsif p_action='reject' then
  if b.status<>'pending' then raise exception 'Booking not pending';end if;
  update public.bookings set status='rejected' where id=p_id;
 elsif p_action='cancel' then
  if b.status<>'confirmed' or b.checked_in_at is not null then raise exception 'Cannot cancel this booking';end if;
  update public.bookings set status='cancelled' where id=p_id;
 elsif p_action='collect' then
  if b.status<>'confirmed' or b.complimentary or b.checked_in_at is not null or b.payment_method<>'cash' then
   raise exception 'Not eligible for cash collection';end if;
  update public.bookings set amount_collected=amount_due where id=p_id;
 else raise exception 'Unknown action';end if;
 insert into public.notifications(title,message,booking_id) values('Booking updated',b.reference||': '||p_action,p_id);
end $$;
