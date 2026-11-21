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
