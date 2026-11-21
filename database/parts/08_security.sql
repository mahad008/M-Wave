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
