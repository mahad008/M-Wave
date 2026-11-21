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
