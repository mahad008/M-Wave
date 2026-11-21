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
