> Note: this technical file was written before the folders were tidied. Use START_HERE.md for setup. In this note, "sql/" means "database/parts/", and 06/09 tests are "database/tests/".

# M-WAVE: database + front end (Steps 1-9 of the plan)

Tested on PostgreSQL 16 from a clean build: 17/17 rule checks (`06_demo_test.sql`), 48/48 role checks (`09_security_test.sql`),
28/28 data-layer checks over a real PostgREST API (the same API layer Supabase uses) and 36/36 click-through checks of the front end.

## Run it on Supabase
1. Create a Supabase project (free tier).
2. **SQL Editor** > paste all of `mwave_all.sql` > **Run**. (Resets, then builds tables, triggers, functions, views, sample data and security.)
3. Paste `sql/06_demo_test.sql` > Run: 17 rows, all PASS.
4. Run `mwave_all.sql` again (fresh data), then paste `sql/09_security_test.sql` > Run: 48 rows, all PASS.
   (Each test expects fresh sample data, so rebuild between them.)
5. For the profiling slide: save your `EXPLAIN ANALYZE` results, run `sql/07_indexes.sql`, run `EXPLAIN ANALYZE` again.

If you change a file in `sql/`, run `sh build_all.sh` to rebuild `mwave_all.sql`.
`tests/local_supabase_stub.sql` is ONLY for testing on a plain local PostgreSQL. Do not run it on Supabase.

## Files
| File | Step | What it does |
|---|---|---|
| 00_reset.sql | - | Drops all M-WAVE objects so you can start over |
| 01_schema.sql | 1 | Enum types, 14 tables, constraints |
| 02_triggers.sql | 2 | State machine, history log, read-only audit tables, price cap, fraud flags, penalties |
| 03_functions.sql | 3 | The app's functions, each checking who is calling |
| 04_views.sql | 4 | 3 materialized views + driver_scores |
| 05_seed.sql | 5 | Sample data |
| 06_demo_test.sql | 6 | 17 rule checks (PASS/FAIL) |
| 07_indexes.sql | 7 | 4 indexes for the profiling slide |
| 08_security.sql | 8 | Row Level Security, blocked direct writes, function permissions |
| 09_security_test.sql | 8 | 48 checks acting as household / driver / operator / regulator / anonymous |

## Who can do what (Step 8)
| Role | Can see | Can do (through functions only) |
|---|---|---|
| Household | own household, orders, usage, history, meter reading | place_order, cancel_order, get_my_otp, rate_order |
| Driver | orders assigned to them, delivery address, own penalties and score | mark_delivered, verify_otp |
| Station operator | orders filled at their station | record_fill, dispatch_order |
| Regulator | everything, including fraud flags | reports, refresh_reports, penalize_unverified, cancel_order |
| Not logged in | nothing | nothing |

Nobody can INSERT / UPDATE / DELETE a table directly, `otp_hash` is unreadable, and the audit tables stay read-only.

## Rules the front end follows
- On `orders`, select columns by name. `select *` fails because `otp_hash` is blocked.
- Regulator reports: call `report_unfulfilled_demand()`, `report_station_throughput()`, `report_driver_turnaround()` (use `supabase.rpc(...)`). The materialized views cannot be read directly.


## Run the front end (Step 9)
Files are in `frontend/`: `index.html`, `style.css`, `app.js` (screens), `api.js` (all database calls), `config.js` (your keys).

1. Supabase > **Project Settings > API**: copy the **Project URL** and the **anon public** key into `frontend/config.js`.
   Never use the `service_role` key in the front end.
2. Create one login per role you want to demo: **Authentication > Users > Add user**, tick **Auto Confirm User**.
   Copy each user's **UID** and link it to a seeded profile in the SQL Editor:
   ```sql
   update profiles set user_id = '<UID>' where full_name = 'Ali Raza';        -- household
   update profiles set user_id = '<UID>' where full_name = 'Kamran Driver';   -- driver
   update profiles set user_id = '<UID>' where full_name = 'Station Op 1';    -- station operator
   update profiles set user_id = '<UID>' where full_name = 'Regulator';       -- regulator
   ```
3. Serve the folder (opening index.html directly can also work, but a server is safer):
   `cd frontend` then `python -m http.server 8000`, and open http://localhost:8000
   For the class demo you can also upload the `frontend` folder to Netlify or GitHub Pages for a free public link.

**Screens:** Household = quota bar, book / cancel, one-time OTP box, rate, order history.
Driver = delivery address, mark delivered, enter OTP, rating and penalties.
Operator = record meter reading, dispatch, audit log with over-capacity warning.
Regulator = city overview, 3 reports + refresh, driver scores, fraud flags, latest orders.

**Suggested demo script (about 5 minutes):** household books 4000 L (show the quota bar move) > try 7000 L more (rejected) >
operator records the fill and dispatches > household taps Get OTP > driver marks delivered, enters a wrong code, then the right one >
household rates and opens History > operator records a fill above tanker capacity > regulator sees the OVERFILL flag and refreshes the reports.

## Design choices to know about
- Quota is reserved when the order is placed; cancelling gives the litres back.
- Over quota = rejected. No free tanker = WAITING, assigned automatically when one frees up.
- Price is set by the system (tanker rate x volume); the price-cap trigger blocks anything above the official rate.
- `verify_otp` returns text ('VERIFIED', 'WRONG_OTP', 'LOCKED', 'EXPIRED') instead of raising, so wrong attempts and the fraud flag are saved.
- Admin sessions (SQL Editor, service key) pass the permission checks; only app users (anon / authenticated) are restricted.

## Next steps
10. ER diagram in ERDPlus, EXPLAIN ANALYZE results (before and after `07_indexes.sql`), report and demo rehearsal.
