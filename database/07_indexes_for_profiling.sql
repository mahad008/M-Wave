-- M-WAVE  |  07_indexes.sql
-- STEP 7: run AFTER you have saved the "before" EXPLAIN ANALYZE results.
create index if not exists idx_orders_status_booked   on orders(status, booked_at);
create index if not exists idx_orders_household_time  on orders(household_id, booked_at);
create index if not exists idx_orders_driver_status   on orders(driver_id, status);
create index if not exists idx_filling_station_time   on filling_audit(station_id, recorded_at);
