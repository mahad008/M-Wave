-- M-WAVE  |  09_security_test.sql
-- STEP 8 test: acts as each kind of app user (household, driver, operator, regulator, anonymous)
-- and checks that allowed things work and forbidden things are refused.
-- Run on a FRESH build (mwave_all.sql) from the SQL Editor / psql as the admin (postgres) user.
-- Do not run it together with 06_demo_test.sql without rebuilding first: both expect fresh sample data.

drop table if exists sec_results;
create temp table sec_results(n serial, test text, got text, pass boolean);

-- run one statement "as" an app user: sets the role and the login id exactly like the Supabase API does
create or replace function pg_temp.act(p_uid uuid, p_role text, p_sql text) returns text
language plpgsql as $$
declare v text;
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  begin
    if left(ltrim(lower(p_sql)), 6) = 'select' then execute p_sql into v; else execute p_sql; end if;
    v := coalesce(nullif(v, ''), 'OK');
  exception when others then
    v := 'ERR: ' || sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  return v;
end $$;

do $$
declare
  hh1 uuid := '00000000-0000-0000-0000-000000000001';   -- Ali Raza, household 1 (Gulshan)
  hh2 uuid := '00000000-0000-0000-0000-000000000002';   -- Sara Khan, household 2 (Gulshan)
  dr1 uuid := '00000000-0000-0000-0000-000000000011';   -- driver 1 (tanker 1)
  dr2 uuid := '00000000-0000-0000-0000-000000000012';   -- driver 2 (tanker 2)
  op1 uuid := '00000000-0000-0000-0000-000000000021';   -- operator, Gulshan station
  op2 uuid := '00000000-0000-0000-0000-000000000022';   -- operator, Korangi station
  rg  uuid := '00000000-0000-0000-0000-000000000031';   -- regulator
  otp text; g text;
begin

  g := pg_temp.act(hh1,'authenticated','select place_order(1, 4000)::text');
  insert into sec_results(test,got,pass) values ('1. Household 1 books 4000 L through place_order', g, g='1');
  g := pg_temp.act(hh2,'authenticated','select place_order(2, 5000)::text');
  insert into sec_results(test,got,pass) values ('2. Household 2 books 5000 L', g, g='2');

  g := pg_temp.act(hh1,'authenticated','select place_order(2, 1000)::text');
  insert into sec_results(test,got,pass) values ('3. Household 1 tries to book for household 2', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(hh1,'authenticated','select place_order(1, 7000)::text');
  insert into sec_results(test,got,pass) values ('4. Quota still enforced for app users', g, g like 'ERR: Monthly quota exceeded%');
  g := pg_temp.act(null,'anon','select place_order(1, 100)::text');
  insert into sec_results(test,got,pass) values ('5. Anonymous (not logged in) calls place_order', g, g like 'ERR: permission denied%');

  -- who sees which orders
  g := pg_temp.act(hh1,'authenticated','select count(*)::text from orders');
  insert into sec_results(test,got,pass) values ('6. Household 1 sees only its own orders', g, g='1');
  g := pg_temp.act(dr1,'authenticated','select count(*)::text from orders');
  insert into sec_results(test,got,pass) values ('7. Driver 1 sees only orders assigned to them', g, g='1');
  g := pg_temp.act(op2,'authenticated','select count(*)::text from orders');
  insert into sec_results(test,got,pass) values ('8. Korangi operator sees no Gulshan-station orders', g, g='0');
  g := pg_temp.act(rg,'authenticated','select count(*)::text from orders');
  insert into sec_results(test,got,pass) values ('9. Regulator sees all orders', g, g='2');
  g := pg_temp.act(null,'anon','select count(*)::text from orders');
  insert into sec_results(test,got,pass) values ('10. Anonymous cannot read orders', g, g like 'ERR: permission denied%');

  -- direct writes and secrets
  g := pg_temp.act(hh1,'authenticated','insert into orders(household_id, volume_liters) values (1, 100)');
  insert into sec_results(test,got,pass) values ('11. Direct INSERT into orders is blocked', g, g like 'ERR: permission denied%');
  g := pg_temp.act(hh1,'authenticated','update orders set status = ''VERIFIED'' where order_id = 1');
  insert into sec_results(test,got,pass) values ('12. Direct UPDATE of order status is blocked', g, g like 'ERR: permission denied%');
  g := pg_temp.act(rg,'authenticated','delete from filling_audit');
  insert into sec_results(test,got,pass) values ('13. Even a regulator cannot DELETE audit rows', g, g like 'ERR: permission denied%');
  g := pg_temp.act(hh1,'authenticated','select otp_hash from orders');
  insert into sec_results(test,got,pass) values ('14. Nobody can read the otp_hash column', g, g like 'ERR: permission denied%');

  -- role-specific actions
  g := pg_temp.act(dr1,'authenticated','select record_fill(1, 4000)::text');
  insert into sec_results(test,got,pass) values ('15. Driver cannot record a station fill', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(op2,'authenticated','select record_fill(1, 4000)::text');
  insert into sec_results(test,got,pass) values ('16. Operator of ANOTHER station cannot fill the order', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(op1,'authenticated','select record_fill(1, 4000)::text');
  insert into sec_results(test,got,pass) values ('17. Correct station operator records the fill', g, g='OK');
  g := pg_temp.act(op1,'authenticated','select record_fill(2, 9000)::text');   -- tanker 2 holds 8000 -> overfill
  insert into sec_results(test,got,pass) values ('18. Operator records a 9000 L fill into an 8000 L tanker', g, g='OK');

  g := pg_temp.act(hh1,'authenticated','select count(*)::text from filling_audit');
  insert into sec_results(test,got,pass) values ('19. Household sees the meter reading of its own order only', g, g='1');
  g := pg_temp.act(hh1,'authenticated','select count(*)::text from fraud_flags');
  insert into sec_results(test,got,pass) values ('20. Household cannot see fraud flags', g, g='0');
  g := pg_temp.act(dr2,'authenticated','select count(*)::text from fraud_flags');
  insert into sec_results(test,got,pass) values ('21. Driver cannot see fraud flags', g, g='0');
  g := pg_temp.act(rg,'authenticated','select count(*)::text from fraud_flags');
  insert into sec_results(test,got,pass) values ('22. Regulator sees the OVERFILL flag', g, g='1');

  g := pg_temp.act(hh1,'authenticated','select dispatch_order(1)::text');
  insert into sec_results(test,got,pass) values ('23. Household cannot dispatch', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(op1,'authenticated','select dispatch_order(1)::text');
  insert into sec_results(test,got,pass) values ('24. Operator dispatches the tanker', g, g='OK');

  otp := pg_temp.act(hh2,'authenticated','select get_my_otp(1)');
  insert into sec_results(test,got,pass) values ('25. Another household cannot get the OTP', otp, otp like 'ERR: Not allowed%');
  otp := pg_temp.act(hh1,'authenticated','select get_my_otp(1)');
  insert into sec_results(test,got,pass) values ('26. The owning household gets a 6-digit OTP', 'got a code of length '||length(otp), otp ~ '^[0-9]{6}$');

  g := pg_temp.act(dr2,'authenticated','select mark_delivered(1, 3950)::text');
  insert into sec_results(test,got,pass) values ('27. Wrong driver cannot mark the order delivered', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(op1,'authenticated','select mark_delivered(1, 3950)::text');
  insert into sec_results(test,got,pass) values ('28. Operator cannot mark delivered', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(dr1,'authenticated','select mark_delivered(1, 3950)::text');
  insert into sec_results(test,got,pass) values ('29. Assigned driver marks delivered', g, g='OK');

  g := pg_temp.act(dr2,'authenticated','select verify_otp(1, '''||otp||''')');
  insert into sec_results(test,got,pass) values ('30. Wrong driver cannot verify the OTP', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(dr1,'authenticated','select verify_otp(1, '''||case when otp='000000' then '111111' else '000000' end||''')');
  insert into sec_results(test,got,pass) values ('31. Assigned driver enters a wrong OTP', g, g='WRONG_OTP');
  g := pg_temp.act(dr1,'authenticated','select verify_otp(1, '''||otp||''')');
  insert into sec_results(test,got,pass) values ('32. Assigned driver enters the right OTP', g, g='VERIFIED');

  g := pg_temp.act(hh2,'authenticated','select rate_order(1, 1)::text');
  insert into sec_results(test,got,pass) values ('33. Another household cannot rate the order', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(hh1,'authenticated','select rate_order(1, 5)::text');
  insert into sec_results(test,got,pass) values ('34. Owner rates the order 5', g, g='OK');

  -- visibility of history, usage, penalties, scores, profiles
  g := pg_temp.act(hh1,'authenticated','select count(*)::text from order_status_history');
  insert into sec_results(test,got,pass) values ('35. Household sees the 6-step history of its own order', g, g='6');
  g := pg_temp.act(hh1,'authenticated','select count(*)::text from monthly_usage where household_id = 2');
  insert into sec_results(test,got,pass) values ('36. Household cannot see another household''s usage', g, g='0');
  g := pg_temp.act(dr2,'authenticated','select count(*)::text from driver_penalties');
  insert into sec_results(test,got,pass) values ('37. Driver 2 sees their own overfill penalty', g, g='1');
  g := pg_temp.act(dr1,'authenticated','select count(*)::text from driver_penalties');
  insert into sec_results(test,got,pass) values ('38. Driver 1 has no penalties', g, g='0');
  g := pg_temp.act(dr1,'authenticated','select count(*)::text from driver_scores');
  insert into sec_results(test,got,pass) values ('39. Driver sees only their own row in driver_scores', g, g='1');
  g := pg_temp.act(rg,'authenticated','select count(*)::text from driver_scores');
  insert into sec_results(test,got,pass) values ('40. Regulator sees all 3 drivers in driver_scores', g, g='3');
  g := pg_temp.act(hh1,'authenticated','select count(*)::text from profiles');
  insert into sec_results(test,got,pass) values ('41. Household sees only its own profile', g, g='1');
  g := pg_temp.act(rg,'authenticated','select count(*)::text from profiles');
  insert into sec_results(test,got,pass) values ('42. Regulator sees all 11 profiles', g, g='11');

  -- regulator reports
  g := pg_temp.act(hh1,'authenticated','select count(*)::text from report_station_throughput()');
  insert into sec_results(test,got,pass) values ('43. Household cannot open regulator reports', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(rg,'authenticated','select count(*)::text from mv_station_throughput');
  insert into sec_results(test,got,pass) values ('44. Materialized views are not directly readable', g, g like 'ERR: permission denied%');
  g := pg_temp.act(rg,'authenticated','select refresh_reports()::text');
  insert into sec_results(test,got,pass) values ('45. Regulator refreshes the reports', g, g='OK');
  g := pg_temp.act(rg,'authenticated','select count(*)::text from report_station_throughput()');
  insert into sec_results(test,got,pass) values ('46. Regulator reads station throughput', g||' row(s)', g::int >= 1);

  g := pg_temp.act(hh1,'authenticated','select penalize_unverified(24)::text');
  insert into sec_results(test,got,pass) values ('47. Household cannot run penalize_unverified', g, g like 'ERR: Not allowed%');
  g := pg_temp.act(rg,'authenticated','select penalize_unverified(24)::text');
  insert into sec_results(test,got,pass) values ('48. Regulator runs penalize_unverified', g, g <> '' and g not like 'ERR:%');
end $$;

select n, test, got, case when pass then 'PASS' else 'FAIL' end as result from sec_results order by n;
