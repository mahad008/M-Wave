-- M-WAVE  |  03_functions.sql
-- STEP 3: the stored procedures the app calls.
-- Each one checks WHO is calling (household / driver / operator / regulator).
-- They run with the owner's rights (SECURITY DEFINER) so that app users never need direct write access to the tables.

-- ---------- WHO IS CALLING? (used by the permission checks below and by Row Level Security) ----------
-- Admin sessions (SQL Editor / service key) have role 'none' and pass every check.
-- API users (the app, via the anon / authenticated roles) must match their profile.
create or replace function is_api_caller() returns boolean
language sql stable as $$
  select coalesce(current_setting('role', true), 'none') in ('anon', 'authenticated')
$$;

create or replace function my_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where user_id = current_uid()
$$;

create or replace function my_household_id() returns bigint
language sql stable security definer set search_path = public as $$
  select household_id from households where user_id = current_uid()
$$;

create or replace function my_driver_id() returns bigint
language sql stable security definer set search_path = public as $$
  select driver_id from drivers where user_id = current_uid()
$$;

create or replace function my_station_ids() returns setof bigint
language sql stable security definer set search_path = public as $$
  select station_id from stations where operator_id = current_uid()
$$;

create or replace function assert_regulator() returns void
language plpgsql security definer set search_path = public as $$
begin
  if is_api_caller() and coalesce(my_role()::text, '') <> 'regulator' then
    raise exception 'Not allowed: regulators only';
  end if;
end $$;

create or replace function assert_household_user(p_household bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if is_api_caller() and not exists (
       select 1 from households where household_id = p_household and user_id = current_uid()) then
    raise exception 'Not allowed: this is not your household';
  end if;
end $$;

-- household that owns the order (cancel_or_regulator also lets a regulator cancel)
create or replace function assert_order_household(p_order bigint, p_regulator_ok boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if is_api_caller()
     and not (p_regulator_ok and coalesce(my_role()::text, '') = 'regulator')
     and not exists (select 1 from orders o join households h using (household_id)
                     where o.order_id = p_order and h.user_id = current_uid()) then
    raise exception 'Not allowed: this is not your order';
  end if;
end $$;

-- the driver assigned to the order
create or replace function assert_order_driver(p_order bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if is_api_caller() and not exists (
       select 1 from orders o join drivers d using (driver_id)
       where o.order_id = p_order and d.user_id = current_uid()) then
    raise exception 'Not allowed: this order is not assigned to you';
  end if;
end $$;

-- the operator of the station the order is filled at
create or replace function assert_order_operator(p_order bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if is_api_caller() and not exists (
       select 1 from orders o join stations s using (station_id)
       where o.order_id = p_order and s.operator_id = current_uid()) then
    raise exception 'Not allowed: this order is not filled at your station';
  end if;
end $$;

-- Try to give a WAITING order a tanker + driver + station. Returns true if it worked.
create or replace function try_assign(p_order bigint) returns boolean
language plpgsql set search_path = public, extensions as $$
declare
  o         orders%rowtype;
  v_cap     numeric;
  v_area    bigint;
  v_station bigint;
  r         record;
begin
  select * into o from orders where order_id = p_order and status = 'WAITING' for update;
  if not found then return false; end if;

  v_cap := get_price_cap(o.household_id);
  select area_id into v_area from households where household_id = o.household_id;

  -- cheapest free tanker that: has an unblocked driver, is big enough, and is within the price cap
  select t.tanker_id, d.driver_id, t.price_per_1000l into r
  from tankers t
  join drivers d on d.tanker_id = t.tanker_id
  where t.status = 'AVAILABLE'
    and not d.is_blocked
    and t.capacity_liters >= o.volume_liters
    and t.price_per_1000l <= v_cap
  order by t.price_per_1000l, t.tanker_id
  limit 1
  for update of t skip locked;

  if not found then return false; end if;

  -- prefer a station in the household's own area
  select station_id into v_station from stations
  order by (area_id = v_area) desc, station_id limit 1;

  update tankers set status = 'BUSY' where tanker_id = r.tanker_id;
  update orders
     set tanker_id  = r.tanker_id,
         driver_id  = r.driver_id,
         station_id = v_station,
         price      = round(o.volume_liters / 1000.0 * r.price_per_1000l, 2),
         status     = 'BOOKED'
   where order_id = p_order;
  return true;
end $$;

-- QUOTA ENFORCEMENT: book a tanker for a household. Rejects with a clear message if not allowed.
-- Returns the new order id (status BOOKED, or WAITING if no tanker is free right now).
create or replace function place_order(p_household bigint, p_volume int) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_quota int;
  v_used  int;
  v_month date := date_trunc('month', now())::date;
  v_id    bigint;
begin
  perform assert_household_user(p_household);
  if p_volume is null or p_volume <= 0 then
    raise exception 'Volume must be greater than zero';
  end if;

  select c.monthly_quota_liters into v_quota
  from households h join property_categories c on c.category_id = h.category_id
  where h.household_id = p_household and h.is_active
  for update of h;
  if not found then
    raise exception 'Household % not found or inactive', p_household;
  end if;

  if p_volume > (select coalesce(max(capacity_liters), 0) from tankers) then
    raise exception 'Requested % L is larger than any tanker can carry', p_volume;
  end if;

  insert into monthly_usage(household_id, month) values (p_household, v_month)
  on conflict do nothing;
  select liters_used into v_used from monthly_usage
  where household_id = p_household and month = v_month for update;

  if v_used + p_volume > v_quota then
    raise exception 'Monthly quota exceeded: already booked % L + requested % L is above the % L limit',
      v_used, p_volume, v_quota;
  end if;

  insert into orders(household_id, volume_liters) values (p_household, p_volume)
  returning order_id into v_id;

  -- the quota is reserved at booking time, so a household cannot book more than its limit
  update monthly_usage set liters_used = liters_used + p_volume
   where household_id = p_household and month = v_month;

  perform try_assign(v_id);       -- BOOKED if a tanker is free, otherwise stays WAITING
  return v_id;
end $$;

-- WAITING QUEUE: hand free tankers to waiting orders, oldest first. Returns how many were assigned.
create or replace function assign_waiting_orders() returns int
language plpgsql set search_path = public, extensions as $$
declare r record; n int := 0;
begin
  for r in select order_id from orders where status = 'WAITING' order by booked_at, order_id loop
    if try_assign(r.order_id) then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- Cancel a WAITING or BOOKED order: gives the quota back and frees the tanker.
create or replace function cancel_order(p_order bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare o orders%rowtype;
begin
  perform assert_order_household(p_order, true);
  select * into o from orders where order_id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if o.status not in ('WAITING','BOOKED') then
    raise exception 'Only WAITING or BOOKED orders can be cancelled (this one is %)', o.status;
  end if;

  update monthly_usage set liters_used = liters_used - o.volume_liters
   where household_id = o.household_id and month = date_trunc('month', o.booked_at)::date;
  if o.tanker_id is not null then
    update tankers set status = 'AVAILABLE' where tanker_id = o.tanker_id;
  end if;
  update orders set status = 'CANCELLED' where order_id = p_order;

  perform assign_waiting_orders();
end $$;

-- STATION OPERATOR: record the bulk meter reading. BOOKED -> FILLED. (Writes the read-only audit row.)
create or replace function record_fill(p_order bigint, p_meter_liters int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare o orders%rowtype; v_cap int;
begin
  perform assert_order_operator(p_order);
  select * into o from orders where order_id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if o.status <> 'BOOKED' then
    raise exception 'Order must be BOOKED to record a fill (this one is %)', o.status;
  end if;
  select capacity_liters into v_cap from tankers where tanker_id = o.tanker_id;

  insert into filling_audit(order_id, station_id, tanker_id, meter_liters, tanker_capacity)
  values (o.order_id, o.station_id, o.tanker_id, p_meter_liters, v_cap);   -- overfill trigger may flag it

  update orders set status = 'FILLED' where order_id = p_order;
end $$;

-- STATION OPERATOR: tanker leaves the station. FILLED -> DISPATCHED.
create or replace function dispatch_order(p_order bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_status order_status;
begin
  perform assert_order_operator(p_order);
  select status into v_status from orders where order_id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if v_status <> 'FILLED' then
    raise exception 'Order must be FILLED to dispatch (this one is %)', v_status;
  end if;
  update orders set status = 'DISPATCHED' where order_id = p_order;
end $$;

-- HOUSEHOLD: get the one-time delivery code. Only a bcrypt hash is stored.
create or replace function get_my_otp(p_order bigint) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare o orders%rowtype; v_otp text;
begin
  perform assert_order_household(p_order);
  select * into o from orders where order_id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if o.status not in ('DISPATCHED','DELIVERED') then
    raise exception 'OTP is available only while the order is DISPATCHED or DELIVERED (this one is %)', o.status;
  end if;
  if o.otp_hash is not null then
    raise exception 'An OTP was already issued for this order';
  end if;

  v_otp := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
  update orders
     set otp_hash = crypt(v_otp, gen_salt('bf')), otp_expires_at = now() + interval '30 minutes'
   where order_id = p_order;
  return v_otp;                 -- shown once, never stored in plain text
end $$;

-- DRIVER: report how much water was actually delivered. DISPATCHED -> DELIVERED.
create or replace function mark_delivered(p_order bigint, p_delivered_liters int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_status order_status;
begin
  perform assert_order_driver(p_order);
  select status into v_status from orders where order_id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if v_status <> 'DISPATCHED' then
    raise exception 'Order must be DISPATCHED to mark delivered (this one is %)', v_status;
  end if;
  update orders set delivered_liters = p_delivered_liters, status = 'DELIVERED'
   where order_id = p_order;      -- short-delivery trigger may flag it
end $$;

-- DRIVER: enter the household's code. DELIVERED -> VERIFIED.
-- Returns 'VERIFIED', 'WRONG_OTP', 'LOCKED' (3 wrong tries) or 'EXPIRED'.
-- (Returns text instead of raising, so the wrong-try counter and the fraud flag are saved.)
create or replace function verify_otp(p_order bigint, p_otp text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare o orders%rowtype;
begin
  perform assert_order_driver(p_order);
  select * into o from orders where order_id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if o.status <> 'DELIVERED' then
    raise exception 'Order must be DELIVERED to verify (this one is %)', o.status;
  end if;
  if o.otp_hash is null then raise exception 'No OTP has been issued for this order'; end if;

  if o.otp_attempts >= 3 then return 'LOCKED'; end if;
  if now() > o.otp_expires_at then return 'EXPIRED'; end if;

  if crypt(p_otp, o.otp_hash) = o.otp_hash then
    update orders set otp_verified = true, status = 'VERIFIED' where order_id = p_order;
    update tankers set status = 'AVAILABLE' where tanker_id = o.tanker_id;
    perform assign_waiting_orders();
    return 'VERIFIED';
  end if;

  update orders set otp_attempts = otp_attempts + 1 where order_id = p_order;
  if o.otp_attempts + 1 >= 3 then
    insert into fraud_flags(order_id, tanker_id, flag_type, details)
    values (p_order, o.tanker_id, 'OTP_ABUSE', '3 wrong OTP attempts');
    return 'LOCKED';
  end if;
  return 'WRONG_OTP';
end $$;

-- HOUSEHOLD: rate the delivery (1-5) after it is VERIFIED.
create or replace function rate_order(p_order bigint, p_rating int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare o orders%rowtype;
begin
  perform assert_order_household(p_order);
  select * into o from orders where order_id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if o.status <> 'VERIFIED' then raise exception 'Only VERIFIED orders can be rated'; end if;
  if o.household_rating is not null then raise exception 'Order already rated'; end if;
  update orders set household_rating = p_rating where order_id = p_order;
end $$;

-- REGULATOR / scheduled job: 1 penalty point for each delivery left unverified too long.
create or replace function penalize_unverified(p_hours int default 24) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare r record; n int := 0;
begin
  perform assert_regulator();
  for r in
    select order_id, driver_id from orders o
    where status = 'DELIVERED'
      and delivered_at < now() - make_interval(hours => p_hours)
      and not exists (select 1 from driver_penalties p
                      where p.order_id = o.order_id and p.reason = 'UNVERIFIED')
  loop
    insert into driver_penalties(driver_id, order_id, reason, points)
    values (r.driver_id, r.order_id, 'UNVERIFIED', 1);
    n := n + 1;
  end loop;
  return n;
end $$;
