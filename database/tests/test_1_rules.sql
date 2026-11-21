-- M-WAVE  |  06_demo_test.sql
-- STEP 6: runs every rule once and shows PASS/FAIL per check. Run after 01-05 on a fresh database.
-- It also makes a good live demo: each row says what was tried and what the database did.

drop table if exists demo_results;
create temp table demo_results(n serial, test text, outcome text, pass boolean);

do $$
declare
  o1 bigint; o2 bigint; o3 bigint; o4 bigint;
  otp text; res text; msg text; n int;
begin
  -- 1. normal booking: household 1 asks for 4000 L -> cheapest tanker (800/1000L)
  o1 := place_order(1, 4000);
  insert into demo_results(test,outcome,pass)
  select '1. Book 4000 L (quota 10000)', 'status='||status||', tanker='||tanker_id||', price='||price,
         status='BOOKED' and tanker_id=1 and price=3200 from orders where order_id=o1;

  -- 2. quota enforcement
  begin perform place_order(1, 7000); msg := 'ACCEPTED (bad)';
  exception when others then msg := sqlerrm; end;
  insert into demo_results(test,outcome,pass) values
   ('2. Book 7000 L more (4000+7000 > 10000)', msg, msg like 'Monthly quota exceeded%');

  -- 3. state machine cannot be skipped
  begin update orders set status='DELIVERED' where order_id=o1; msg := 'ACCEPTED (bad)';
  exception when others then msg := sqlerrm; end;
  insert into demo_results(test,outcome,pass) values
   ('3. Jump BOOKED -> DELIVERED', msg, msg like 'Illegal status change%');

  -- 4. fill (audit row) + audit table is read-only
  perform record_fill(o1, 4000);
  begin delete from filling_audit where order_id=o1; msg := 'DELETED (bad)';
  exception when others then msg := sqlerrm; end;
  insert into demo_results(test,outcome,pass) values
   ('4. Delete a filling_audit row', msg, msg like 'filling_audit is read-only%');
  begin update order_status_history set new_status='VERIFIED' where order_id=o1; msg := 'UPDATED (bad)';
  exception when others then msg := sqlerrm; end;
  insert into demo_results(test,outcome,pass) values
   ('5. Edit the status history', msg, msg like 'order_status_history is read-only%');

  -- 6. full delivery with OTP
  perform dispatch_order(o1);
  otp := get_my_otp(o1);
  perform mark_delivered(o1, 3950);
  res := verify_otp(o1, case when otp='000000' then '111111' else '000000' end);
  insert into demo_results(test,outcome,pass) values ('6. Wrong OTP', res, res='WRONG_OTP');
  res := verify_otp(o1, otp);
  insert into demo_results(test,outcome,pass)
  select '7. Correct OTP', res||', order status='||status, res='VERIFIED' and status='VERIFIED'
  from orders where order_id=o1;
  insert into demo_results(test,outcome,pass)
  select '8. History log has every step', count(*)||' rows (expected 6)', count(*)=6
  from order_status_history where order_id=o1;
  insert into demo_results(test,outcome,pass)
  select '9. Stored OTP is hashed, not plain', left(otp_hash,4)||'...', otp_hash <> otp and otp_hash like '$2a$%'
  from orders where order_id=o1;
  perform rate_order(o1, 5);

  -- 10. overfill flag + penalty (household 2 asks 5000 L -> tanker 1 again, capacity 6000)
  o2 := place_order(2, 5000);
  perform record_fill(o2, 6500);
  insert into demo_results(test,outcome,pass)
  select '10. Meter 6500 L > capacity 6000 L', 'flags='||count(*)||' ('||string_agg(flag_type::text,',')||')',
         count(*)=1 and min(flag_type::text)='OVERFILL' from fraud_flags where order_id=o2;

  -- 11. short delivery flag -> driver reaches 5 points and is blocked
  perform dispatch_order(o2);
  perform get_my_otp(o2);
  perform mark_delivered(o2, 4000);
  insert into demo_results(test,outcome,pass)
  select '11. Delivered 4000 of 6500 L loaded', 'penalty_points='||penalty_points||', blocked='||is_blocked,
         penalty_points=5 and is_blocked from drivers where driver_id=1;

  -- 12. price cap: tanker 3 (1000/1000L) is too expensive for apartments -> order waits
  o3 := place_order(3, 5000);                 -- gets tanker 2 (driver 1 is blocked, tanker 1 is busy anyway)
  o4 := place_order(4, 5000);                 -- only tanker 3 is left and it is over the cap
  insert into demo_results(test,outcome,pass)
  select '12. Over-cap tanker is not used', 'order3='||a.status||', order4='||b.status,
         a.status='BOOKED' and a.tanker_id=2 and b.status='WAITING'
  from orders a, orders b where a.order_id=o3 and b.order_id=o4;

  begin update orders set price = 99999 where order_id=o3; msg := 'ACCEPTED (bad)';
  exception when others then msg := sqlerrm; end;
  insert into demo_results(test,outcome,pass) values
   ('13. Force a price above the cap', msg, msg like 'Price % is above the official cap%');

  -- 14. waiting queue: cancelling order 3 frees tanker 2 for the waiting order 4
  perform cancel_order(o3);
  insert into demo_results(test,outcome,pass)
  select '14. Cancel order 3 -> waiting order 4 gets the tanker',
         'order4='||status||', tanker='||coalesce(tanker_id::text,'-'), status='BOOKED' and tanker_id=2
  from orders where order_id=o4;
  insert into demo_results(test,outcome,pass)
  select '15. Cancel gives quota back (household 3 back to 0 L used)', 'liters_used='||liters_used, liters_used=0
  from monthly_usage where household_id=3;

  -- 16. three wrong OTPs lock the order and raise a fraud flag
  perform record_fill(o4, 5000); perform dispatch_order(o4); perform get_my_otp(o4); perform mark_delivered(o4, 5000);
  perform verify_otp(o4,'000000'); perform verify_otp(o4,'000000'); res := verify_otp(o4,'000000');
  insert into demo_results(test,outcome,pass)
  select '16. Three wrong OTPs', res||', OTP_ABUSE flags='||count(*), res='LOCKED' and count(*)=1
  from fraud_flags where order_id=o4 and flag_type='OTP_ABUSE';

  -- 17. unverified-delivery penalty
  update orders set delivered_at = now() - interval '2 days' where order_id=o2;   -- test-only time shift
  n := penalize_unverified(24);
  insert into demo_results(test,outcome,pass) values ('17. Penalize unverified deliveries (>24h)', n||' order(s) penalized', n>=1);
end $$;

select n, test, outcome, case when pass then 'PASS' else 'FAIL' end as result from demo_results order by n;
