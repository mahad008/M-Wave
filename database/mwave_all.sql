-- M-WAVE  |  00_reset.sql
-- Wipes everything M-WAVE created so you can re-run the scripts from scratch.
-- Only touches M-WAVE objects. Safe to run on a fresh project too.

drop materialized view if exists mv_unfulfilled_demand, mv_station_throughput, mv_driver_turnaround cascade;
drop view if exists driver_scores cascade;

drop table if exists driver_penalties, fraud_flags, filling_audit, order_status_history,
                     monthly_usage, orders, price_rates, drivers, tankers, stations,
                     households, property_categories, areas, profiles cascade;

do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and (p.proname like 'trg\_%' or p.proname like 'assert\_%' or p.proname like 'report\_%' or p.proname in (
               'current_uid','get_price_cap','try_assign','place_order','assign_waiting_orders',
               'cancel_order','record_fill','dispatch_order','mark_delivered','get_my_otp',
               'verify_otp','rate_order','penalize_unverified','is_api_caller','my_role','my_household_id',
               'my_driver_id','my_station_ids','refresh_reports'))
  loop execute 'drop function if exists ' || r.sig || ' cascade'; end loop;
end $$;

drop type if exists user_role, order_status, tanker_status, flag_type cascade;
-- M-WAVE  |  01_schema.sql
-- STEP 1: extensions, enum types, 14 tables, constraints.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;   -- used for OTP hashing

-- ---------- enum types (no invalid value can ever be stored) ----------
create type user_role     as enum ('household','driver','operator','regulator');
create type order_status  as enum ('WAITING','BOOKED','FILLED','DISPATCHED','DELIVERED','VERIFIED','CANCELLED');
create type tanker_status as enum ('AVAILABLE','BUSY','BLOCKED');
create type flag_type     as enum ('OVERFILL','SHORT_DELIVERY','OTP_ABUSE');

-- ---------- setup and people ----------
create table profiles (
  user_id    uuid primary key,          -- on Supabase this is the same id as auth.users.id
  role       user_role not null,
  full_name  text      not null,
  phone      text
);

create table areas (
  area_id bigint generated always as identity primary key,
  name    text not null unique,
  zone    text
);

create table property_categories (
  category_id          bigint generated always as identity primary key,
  name                 text not null unique,
  monthly_quota_liters int  not null check (monthly_quota_liters > 0)
);

create table households (
  household_id bigint generated always as identity primary key,
  user_id      uuid   not null unique references profiles(user_id) on update cascade,
  area_id      bigint not null references areas(area_id),
  category_id  bigint not null references property_categories(category_id),
  address      text   not null,
  is_active    boolean not null default true
);

create table stations (
  station_id  bigint generated always as identity primary key,
  name        text   not null unique,
  area_id     bigint not null references areas(area_id),
  operator_id uuid   references profiles(user_id) on update cascade
);

create table tankers (
  tanker_id       bigint generated always as identity primary key,
  plate_no        text not null unique,
  capacity_liters int  not null check (capacity_liters > 0),
  price_per_1000l numeric(10,2) not null check (price_per_1000l >= 0),
  status          tanker_status not null default 'AVAILABLE'
);

create table drivers (
  driver_id      bigint generated always as identity primary key,
  user_id        uuid   not null unique references profiles(user_id) on update cascade,
  license_no     text   not null unique,
  tanker_id      bigint unique references tankers(tanker_id),   -- one driver per tanker
  penalty_points int    not null default 0 check (penalty_points >= 0),
  is_blocked     boolean not null default false
);

-- official price cap per property category (newest row that has started wins)
create table price_rates (
  rate_id             bigint generated always as identity primary key,
  category_id         bigint not null references property_categories(category_id),
  max_price_per_1000l numeric(10,2) not null check (max_price_per_1000l > 0),
  effective_from      timestamptz not null default now(),
  unique (category_id, effective_from)
);

-- ---------- orders and tracking ----------
create table orders (
  order_id         bigint generated always as identity primary key,
  household_id     bigint not null references households(household_id),
  tanker_id        bigint references tankers(tanker_id),
  driver_id        bigint references drivers(driver_id),
  station_id       bigint references stations(station_id),
  volume_liters    int    not null check (volume_liters > 0),
  price            numeric(12,2) check (price is null or price >= 0),
  status           order_status not null default 'WAITING',
  otp_hash         text,
  otp_attempts     int not null default 0 check (otp_attempts >= 0),
  otp_expires_at   timestamptz,
  otp_verified     boolean not null default false,
  delivered_liters int check (delivered_liters is null or delivered_liters >= 0),
  household_rating smallint check (household_rating between 1 and 5),
  booked_at        timestamptz not null default now(),   -- time the order was placed
  filled_at        timestamptz,
  dispatched_at    timestamptz,
  delivered_at     timestamptz,
  verified_at      timestamptz,
  -- once an order is past WAITING it must have a tanker, driver and price
  constraint orders_assigned_chk check (
    status in ('WAITING','CANCELLED')
    or (tanker_id is not null and driver_id is not null and price is not null)
  )
);

-- one row per household per month (first day of the month); the quota check reads this
create table monthly_usage (
  household_id bigint not null references households(household_id),
  month        date   not null check (extract(day from month) = 1),
  liters_used  int    not null default 0 check (liters_used >= 0),
  primary key (household_id, month)
);

-- READ-ONLY (protected by triggers in step 2)
create table order_status_history (
  history_id bigint generated always as identity primary key,
  order_id   bigint not null references orders(order_id),
  old_status order_status,
  new_status order_status not null,
  changed_by uuid,
  changed_at timestamptz not null default now()
);

-- ---------- audit and control ----------
-- READ-ONLY (protected by triggers in step 2): one row per tanker filling
create table filling_audit (
  audit_id        bigint generated always as identity primary key,
  order_id        bigint not null unique references orders(order_id),
  station_id      bigint not null references stations(station_id),
  tanker_id       bigint not null references tankers(tanker_id),
  meter_liters    int    not null check (meter_liters > 0),
  tanker_capacity int    not null check (tanker_capacity > 0),
  recorded_at     timestamptz not null default now()
);

create table fraud_flags (
  flag_id    bigint generated always as identity primary key,
  order_id   bigint not null references orders(order_id),
  tanker_id  bigint references tankers(tanker_id),
  flag_type  flag_type not null,
  details    text,
  created_at timestamptz not null default now(),
  resolved   boolean not null default false
);

create table driver_penalties (
  penalty_id bigint generated always as identity primary key,
  driver_id  bigint not null references drivers(driver_id),
  order_id   bigint references orders(order_id),
  reason     text   not null,
  points     int    not null check (points > 0),
  created_at timestamptz not null default now()
);
-- M-WAVE  |  02_triggers.sql
-- STEP 2: rules the database enforces automatically.

-- ---------- helpers ----------
-- Who is calling? On Supabase this reads the logged-in user's id from the request token.
-- In a plain SQL session it returns NULL.
create or replace function current_uid() returns uuid
language sql stable as $$
  select coalesce(
           nullif(current_setting('request.jwt.claim.sub', true), ''),
           nullif(current_setting('request.jwt.claims', true), '')::json ->> 'sub'
         )::uuid
$$;

-- Official price cap (per 1000 L) for a household's property category
create or replace function get_price_cap(p_household bigint) returns numeric
language sql stable as $$
  select r.max_price_per_1000l
  from households h
  join price_rates r on r.category_id = h.category_id and r.effective_from <= now()
  where h.household_id = p_household
  order by r.effective_from desc
  limit 1
$$;

-- ---------- 1. STATE MACHINE on orders ----------
-- WAITING -> BOOKED -> FILLED -> DISPATCHED -> DELIVERED -> VERIFIED
-- (WAITING or BOOKED can also go to CANCELLED). Anything else is rejected.
create or replace function trg_orders_state() returns trigger
language plpgsql as $$
begin
  if NEW.status = OLD.status then
    return NEW;
  end if;

  if (OLD.status::text || '>' || NEW.status::text) <> all (array[
        'WAITING>BOOKED','WAITING>CANCELLED','BOOKED>FILLED','BOOKED>CANCELLED',
        'FILLED>DISPATCHED','DISPATCHED>DELIVERED','DELIVERED>VERIFIED']) then
    raise exception 'Illegal status change: % -> %', OLD.status, NEW.status;
  end if;

  if NEW.status = 'DELIVERED' and NEW.delivered_liters is null then
    raise exception 'Cannot mark DELIVERED without delivered_liters';
  end if;
  if NEW.status = 'VERIFIED' and not NEW.otp_verified then
    raise exception 'Cannot mark VERIFIED: OTP was not verified';
  end if;

  case NEW.status
    when 'FILLED'     then NEW.filled_at     := now();
    when 'DISPATCHED' then NEW.dispatched_at := now();
    when 'DELIVERED'  then NEW.delivered_at  := now();
    when 'VERIFIED'   then NEW.verified_at   := now();
    else null;
  end case;
  return NEW;
end $$;

create trigger orders_state before update on orders
  for each row execute function trg_orders_state();

-- ---------- 2. DELIVERY HISTORY LOG ----------
create or replace function trg_orders_history() returns trigger
language plpgsql as $$
begin
  if TG_OP = 'INSERT' then
    insert into order_status_history(order_id, old_status, new_status, changed_by)
    values (NEW.order_id, null, NEW.status, current_uid());
  elsif NEW.status <> OLD.status then
    insert into order_status_history(order_id, old_status, new_status, changed_by)
    values (NEW.order_id, OLD.status, NEW.status, current_uid());
  end if;
  return null;
end $$;

create trigger orders_history after insert or update on orders
  for each row execute function trg_orders_history();

-- ---------- 3. READ-ONLY AUDIT TABLES ----------
create or replace function trg_block_changes() returns trigger
language plpgsql as $$
begin
  raise exception '% is read-only: % is not allowed', TG_TABLE_NAME, TG_OP;
end $$;

create trigger filling_audit_ro before update or delete on filling_audit
  for each row execute function trg_block_changes();
create trigger filling_audit_ro_trunc before truncate on filling_audit
  for each statement execute function trg_block_changes();

create trigger history_ro before update or delete on order_status_history
  for each row execute function trg_block_changes();
create trigger history_ro_trunc before truncate on order_status_history
  for each statement execute function trg_block_changes();

-- ---------- 4. PRICE CAP ----------
create or replace function trg_orders_price_cap() returns trigger
language plpgsql as $$
declare v_cap numeric;
begin
  if NEW.price is null then
    return NEW;
  end if;
  v_cap := get_price_cap(NEW.household_id);
  if v_cap is null then
    raise exception 'No official price rate defined for this household''s category';
  end if;
  if NEW.price > round(NEW.volume_liters / 1000.0 * v_cap, 2) then
    raise exception 'Price % is above the official cap of % for % liters',
      NEW.price, round(NEW.volume_liters / 1000.0 * v_cap, 2), NEW.volume_liters;
  end if;
  return NEW;
end $$;

create trigger orders_price_cap before insert or update of price, volume_liters, household_id on orders
  for each row execute function trg_orders_price_cap();

-- ---------- 5. FRAUD FLAGS ----------
-- Overfill: station meter shows more water than the tanker can hold
create or replace function trg_audit_overfill() returns trigger
language plpgsql as $$
begin
  if NEW.meter_liters > NEW.tanker_capacity then
    insert into fraud_flags(order_id, tanker_id, flag_type, details)
    values (NEW.order_id, NEW.tanker_id, 'OVERFILL',
            format('Meter %s L is above tanker capacity %s L', NEW.meter_liters, NEW.tanker_capacity));
  end if;
  return null;
end $$;

create trigger filling_audit_overfill after insert on filling_audit
  for each row execute function trg_audit_overfill();

-- Short delivery: household received less than 90% of what the meter says was loaded
create or replace function trg_orders_short_delivery() returns trigger
language plpgsql as $$
declare v_meter int;
begin
  select meter_liters into v_meter from filling_audit where order_id = NEW.order_id;
  if v_meter is not null and NEW.delivered_liters < 0.9 * v_meter then
    insert into fraud_flags(order_id, tanker_id, flag_type, details)
    values (NEW.order_id, NEW.tanker_id, 'SHORT_DELIVERY',
            format('Loaded %s L but delivered only %s L', v_meter, NEW.delivered_liters));
  end if;
  return null;
end $$;

create trigger orders_short_delivery after update of status on orders
  for each row when (NEW.status = 'DELIVERED' and OLD.status <> 'DELIVERED')
  execute function trg_orders_short_delivery();

-- ---------- 6. DRIVER PENALTIES ----------
-- every fraud flag gives the order's driver penalty points
create or replace function trg_flag_penalty() returns trigger
language plpgsql as $$
declare v_driver bigint;
begin
  select driver_id into v_driver from orders where order_id = NEW.order_id;
  if v_driver is not null then
    insert into driver_penalties(driver_id, order_id, reason, points)
    values (v_driver, NEW.order_id, NEW.flag_type::text,
            case NEW.flag_type when 'OVERFILL' then 3 else 2 end);
  end if;
  return null;
end $$;

create trigger fraud_flags_penalty after insert on fraud_flags
  for each row execute function trg_flag_penalty();

-- 5 or more points blocks the driver from new bookings
create or replace function trg_penalty_apply() returns trigger
language plpgsql as $$
begin
  update drivers
     set penalty_points = penalty_points + NEW.points,
         is_blocked     = (penalty_points + NEW.points) >= 5
   where driver_id = NEW.driver_id;
  return null;
end $$;

create trigger penalties_apply after insert on driver_penalties
  for each row execute function trg_penalty_apply();
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
-- M-WAVE  |  04_views.sql
-- STEP 4: reports for the regulator.
-- Materialized views store their result, so refresh them to see new data:
--   refresh materialized view mv_unfulfilled_demand;   (etc.)

-- Orders stuck in WAITING per area, and how heavy that is per household
create materialized view mv_unfulfilled_demand as
select a.area_id,
       a.name                                                        as area,
       count(distinct h.household_id)                                as households,
       count(o.order_id) filter (where o.status = 'WAITING')         as waiting_orders,
       coalesce(sum(o.volume_liters) filter (where o.status = 'WAITING'), 0) as waiting_liters,
       round(count(o.order_id) filter (where o.status = 'WAITING')::numeric
             / nullif(count(distinct h.household_id), 0), 3)         as demand_density
from areas a
left join households h on h.area_id = a.area_id
left join orders o      on o.household_id = h.household_id
group by a.area_id, a.name;
create unique index on mv_unfulfilled_demand(area_id);

-- Fillings and litres loaded per station per day (from the read-only audit table)
create materialized view mv_station_throughput as
select s.station_id,
       s.name                                    as station,
       date_trunc('day', f.recorded_at)::date    as day,
       count(*)                                  as fillings,
       sum(f.meter_liters)                       as liters_filled
from filling_audit f
join stations s on s.station_id = f.station_id
group by s.station_id, s.name, date_trunc('day', f.recorded_at)::date;
create unique index on mv_station_throughput(station_id, day);

-- Average time from booking to a verified delivery, per driver
create materialized view mv_driver_turnaround as
select d.driver_id,
       p.full_name                                         as driver,
       count(o.order_id)                                   as verified_deliveries,
       avg(o.verified_at - o.booked_at)                    as avg_turnaround
from drivers d
join profiles p on p.user_id = d.user_id
left join orders o on o.driver_id = d.driver_id and o.status = 'VERIFIED'
group by d.driver_id, p.full_name;
create unique index on mv_driver_turnaround(driver_id);

-- Normal (always up to date) view: rating and penalties per driver.
-- security_invoker = the caller's Row Level Security applies (a driver sees only their own row).
create view driver_scores with (security_invoker = true) as
select d.driver_id,
       p.full_name                         as driver,
       round(avg(o.household_rating), 2)   as avg_rating,
       d.penalty_points,
       d.is_blocked
from drivers d
join profiles p on p.user_id = d.user_id
left join orders o on o.driver_id = d.driver_id
group by d.driver_id, p.full_name, d.penalty_points, d.is_blocked;

-- On Supabase you can refresh the reports automatically (enable pg_cron under Database > Extensions):
-- select cron.schedule('refresh-mwave-reports', '*/15 * * * *', $$
--   refresh materialized view mv_unfulfilled_demand;
--   refresh materialized view mv_station_throughput;
--   refresh materialized view mv_driver_turnaround; $$);
-- M-WAVE  |  05_seed.sql
-- STEP 5: sample data for testing and the class demo (fictional).

insert into profiles(user_id, role, full_name, phone) values
 ('00000000-0000-0000-0000-000000000001','household','Ali Raza',      '0300-0000001'),
 ('00000000-0000-0000-0000-000000000002','household','Sara Khan',     '0300-0000002'),
 ('00000000-0000-0000-0000-000000000003','household','Hamza Sheikh',  '0300-0000003'),
 ('00000000-0000-0000-0000-000000000004','household','Ayesha Malik',  '0300-0000004'),
 ('00000000-0000-0000-0000-000000000005','household','Bilal Traders', '0300-0000005'),
 ('00000000-0000-0000-0000-000000000011','driver',   'Kamran Driver', '0311-0000011'),
 ('00000000-0000-0000-0000-000000000012','driver',   'Imran Driver',  '0311-0000012'),
 ('00000000-0000-0000-0000-000000000013','driver',   'Faisal Driver', '0311-0000013'),
 ('00000000-0000-0000-0000-000000000021','operator', 'Station Op 1',  '0322-0000021'),
 ('00000000-0000-0000-0000-000000000022','operator', 'Station Op 2',  '0322-0000022'),
 ('00000000-0000-0000-0000-000000000031','regulator','Regulator',     '0333-0000031');

insert into areas(name, zone) values ('Gulshan','East'), ('Korangi','South'), ('Saddar','Central');

insert into property_categories(name, monthly_quota_liters) values
 ('Small house', 10000), ('Apartment', 6000), ('Commercial', 30000);

-- official price caps (sample numbers, per 1000 L)
insert into price_rates(category_id, max_price_per_1000l) values (1, 900), (2, 900), (3, 1500);

insert into households(user_id, area_id, category_id, address) values
 ('00000000-0000-0000-0000-000000000001', 1, 1, 'House 12, Gulshan'),
 ('00000000-0000-0000-0000-000000000002', 1, 1, 'House 40, Gulshan'),
 ('00000000-0000-0000-0000-000000000003', 2, 2, 'Flat 5, Korangi'),
 ('00000000-0000-0000-0000-000000000004', 2, 2, 'Flat 9, Korangi'),
 ('00000000-0000-0000-0000-000000000005', 3, 3, 'Shop 3, Saddar');

insert into stations(name, area_id, operator_id) values
 ('Gulshan Hydrant', 1, '00000000-0000-0000-0000-000000000021'),
 ('Korangi Hydrant', 2, '00000000-0000-0000-0000-000000000022');

-- tanker 3 charges 1000 per 1000 L: above the residential cap (900), so only commercial can use it
insert into tankers(plate_no, capacity_liters, price_per_1000l) values
 ('KHI-1001', 6000, 800), ('KHI-1002', 8000, 850), ('KHI-1003', 12000, 1000);

insert into drivers(user_id, license_no, tanker_id) values
 ('00000000-0000-0000-0000-000000000011','LIC-001', 1),
 ('00000000-0000-0000-0000-000000000012','LIC-002', 2),
 ('00000000-0000-0000-0000-000000000013','LIC-003', 3);
-- M-WAVE  |  08_security.sql
-- STEP 8: Row Level Security (who can see what) + locking down direct writes.
-- Run this LAST (after 01-05), because it removes default permissions from the tables.
--
-- The rules:
--   * App users (anon / authenticated) can NOT insert, update or delete any table directly.
--     Every change goes through the functions in 03_functions.sql, which check who is calling.
--   * App users can SELECT only the rows their role is allowed to see (policies below).
--   * The OTP hash column is never readable by app users.

-- ---------- 1. table permissions ----------
revoke all on all tables in schema public from anon, authenticated;

-- reference data: any logged-in user can read
grant select on areas, property_categories, price_rates, stations, tankers to authenticated;
-- data protected by row policies
grant select on profiles, households, drivers, monthly_usage, order_status_history,
                filling_audit, fraud_flags, driver_penalties to authenticated;
-- orders: every column EXCEPT otp_hash
grant select (order_id, household_id, tanker_id, driver_id, station_id, volume_liters, price, status,
              otp_attempts, otp_expires_at, otp_verified, delivered_liters, household_rating,
              booked_at, filled_at, dispatched_at, delivered_at, verified_at)
  on orders to authenticated;
grant select on driver_scores to authenticated;      -- security_invoker view: policies still apply

-- ---------- 2. turn on Row Level Security ----------
alter table profiles             enable row level security;
alter table areas                enable row level security;
alter table property_categories  enable row level security;
alter table households           enable row level security;
alter table stations             enable row level security;
alter table tankers              enable row level security;
alter table drivers              enable row level security;
alter table price_rates          enable row level security;
alter table orders               enable row level security;
alter table monthly_usage        enable row level security;
alter table order_status_history enable row level security;
alter table filling_audit        enable row level security;
alter table fraud_flags          enable row level security;
alter table driver_penalties     enable row level security;

-- ---------- 3. who sees which rows ----------
create policy profiles_read on profiles for select to authenticated
  using (user_id = current_uid() or my_role() = 'regulator');

create policy areas_read      on areas               for select to authenticated using (true);
create policy categories_read on property_categories for select to authenticated using (true);
create policy rates_read      on price_rates         for select to authenticated using (true);
create policy stations_read   on stations            for select to authenticated using (true);
create policy tankers_read    on tankers             for select to authenticated using (true);

-- a household sees itself; a driver/operator sees the households of orders they can see (delivery address)
create policy households_read on households for select to authenticated
  using (user_id = current_uid()
         or my_role() = 'regulator'
         or exists (select 1 from orders o where o.household_id = households.household_id));

create policy drivers_read on drivers for select to authenticated
  using (user_id = current_uid() or my_role() = 'regulator');

-- orders: household = own, driver = assigned to them, operator = filled at their station, regulator = all
create policy orders_read on orders for select to authenticated
  using (my_role() = 'regulator'
         or household_id = my_household_id()
         or driver_id    = my_driver_id()
         or station_id in (select my_station_ids()));

create policy usage_read on monthly_usage for select to authenticated
  using (my_role() = 'regulator' or household_id = my_household_id());

-- history and audit rows are visible to whoever can see the order they belong to
create policy history_read on order_status_history for select to authenticated
  using (exists (select 1 from orders o where o.order_id = order_status_history.order_id));
create policy audit_read on filling_audit for select to authenticated
  using (exists (select 1 from orders o where o.order_id = filling_audit.order_id));

-- fraud flags: regulator only. Penalties: regulator, or the driver they belong to.
create policy flags_read on fraud_flags for select to authenticated
  using (my_role() = 'regulator');
create policy penalties_read on driver_penalties for select to authenticated
  using (my_role() = 'regulator' or driver_id = my_driver_id());

-- ---------- 4. regulator reports ----------
-- Materialized views cannot use Row Level Security, so app users get no direct access to them.
-- Regulators read them through these functions instead.
create or replace function report_unfulfilled_demand() returns setof mv_unfulfilled_demand
language plpgsql security definer set search_path = public as $$
begin perform assert_regulator(); return query select * from mv_unfulfilled_demand order by area_id; end $$;

create or replace function report_station_throughput() returns setof mv_station_throughput
language plpgsql security definer set search_path = public as $$
begin perform assert_regulator(); return query select * from mv_station_throughput order by day, station_id; end $$;

create or replace function report_driver_turnaround() returns setof mv_driver_turnaround
language plpgsql security definer set search_path = public as $$
begin perform assert_regulator(); return query select * from mv_driver_turnaround order by driver_id; end $$;

create or replace function refresh_reports() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_regulator();
  refresh materialized view mv_unfulfilled_demand;
  refresh materialized view mv_station_throughput;
  refresh materialized view mv_driver_turnaround;
end $$;

-- ---------- 5. who may call which function ----------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  place_order(bigint, int), cancel_order(bigint), record_fill(bigint, int), dispatch_order(bigint),
  get_my_otp(bigint), mark_delivered(bigint, int), verify_otp(bigint, text), rate_order(bigint, int),
  penalize_unverified(int),
  report_unfulfilled_demand(), report_station_throughput(), report_driver_turnaround(), refresh_reports(),
  current_uid(), my_role(), my_household_id(), my_driver_id(), my_station_ids()
to authenticated;
-- (try_assign, assign_waiting_orders and the assert_* checks are internal: no app user can call them.)
