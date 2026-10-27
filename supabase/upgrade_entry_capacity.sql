-- Run AFTER schema.sql on an existing installation. Use a new project for first deployment.
create table if not exists public.entry_audit (
 id bigint generated always as identity primary key,
 booking_id uuid not null references public.bookings(id),
 actor uuid references auth.users(id),
 payment_choice text not null check(payment_choice in ('paid','unpaid')),
 entry_choice text not null check(entry_choice in ('entered','not_entered')),
 amount_before numeric(10,2) not null,
 amount_after numeric(10,2) not null,
 recorded_at timestamptz not null default now()
);
alter table public.entry_audit enable row level security;
revoke all on public.entry_audit from anon,authenticated;
create or replace function public.admin_lookup_entry(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b public.bookings%rowtype; gs jsonb;
begin
 if not public.is_admin() then raise exception 'Access denied';end if;
 select * into b from public.bookings where entry_token::text=p_token;
 if not found then return null;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'full_name',g.full_name,'phone',g.phone) order by g.full_name),'[]'::jsonb) into gs from public.guests g where g.booking_id=b.id;
 return jsonb_build_object('reference',b.reference,'status',b.status,'guest_count',b.guest_count,'complimentary',b.complimentary,'amount_due',b.amount_due,'amount_collected',b.amount_collected,'checked_in_at',b.checked_in_at,'guests',gs);
end $$;
create or replace function public.admin_resolve_entry(p_token text,p_payment text,p_entry text) returns void
language plpgsql security definer set search_path='' as $$
declare b public.bookings%rowtype; next_amount numeric(10,2);
begin
 if not public.is_admin() then raise exception 'Access denied';end if;
 if p_payment not in ('paid','unpaid') or p_entry not in ('entered','not_entered') then raise exception 'Invalid selection';end if;
 select * into b from public.bookings where entry_token::text=p_token for update;
 if not found or b.status<>'confirmed' then raise exception 'Ticket invalid or not confirmed';end if;
 if b.checked_in_at is not null then raise exception 'Ticket already checked in';end if;
 -- Never erase an already recorded payment when the operator selects unpaid.
 next_amount:=case when b.complimentary then 0 when p_payment='paid' then b.amount_due else b.amount_collected end;
 update public.bookings set amount_collected=next_amount,checked_in_at=case when p_entry='entered' then now() else null end where id=b.id;
 insert into public.entry_audit(booking_id,actor,payment_choice,entry_choice,amount_before,amount_after)
 values(b.id,auth.uid(),p_payment,p_entry,b.amount_collected,next_amount);
 insert into public.notifications(title,message,booking_id)
 values('Door record',b.reference||': '||p_payment||', '||p_entry,b.id);
end $$;
create or replace function public.admin_set_capacity(p_capacity integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare used integer;
begin
 if not public.is_admin() then raise exception 'Access denied';end if;
 if p_capacity is null or p_capacity<2 or p_capacity>10000 then raise exception 'Capacity must be between 2 and 10000';end if;
 perform 1 from public.event_config where id=1 for update;
 select coalesce(sum(guest_count),0)::integer into used from public.bookings where status='confirmed';
 if p_capacity<used then raise exception 'Cannot reduce below % confirmed guests',used;end if;
 update public.event_config set capacity=p_capacity where id=1;
 insert into public.notifications(title,message) values('Capacity updated','Maximum attendance changed to '||p_capacity);
 return jsonb_build_object('total',p_capacity,'used',used,'remaining',p_capacity-used);
end $$;
revoke all on function public.admin_lookup_entry(text),public.admin_resolve_entry(text,text,text),public.admin_set_capacity(integer) from public,anon;
grant execute on function public.admin_lookup_entry(text),public.admin_resolve_entry(text,text,text),public.admin_set_capacity(integer) to authenticated;
-- Ensure all confirmed reservations and public capacity reads share the same config row lock.
-- The existing approval and complimentary booking RPCs already lock event_config FOR UPDATE.
