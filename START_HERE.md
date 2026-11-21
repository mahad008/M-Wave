# M-WAVE: how to set everything up (plain steps)

**What you have:** a water-tanker booking system. The *database* does the thinking (quota, price limit, OTP, fraud checks).
The *website* is a simple page that talks to it. You will put the database on Supabase (free), then open the website on your computer.

**What you need:** a free Supabase account (https://supabase.com), Google Chrome, and Python (for one command; check with `python --version`, on Windows try `py --version`).
Time: about 30 minutes.

**Folder map**
- `database/mwave_all.sql`: the whole database in one file (this is the main one)
- `database/tests/`: two test files that prove the rules work
- `frontend/`: the website
- `database/parts/`: the same database split into pieces (you can ignore this)
- `README_technical.md`: details for your report (you can ignore this for setup)

---

## PART 1: Put the database on Supabase

**Step 1. Make a project**
1. Sign in at supabase.com and click **New project**.
2. Name it `mwave`. Make up a **database password** and write it down. Pick the region closest to you. Click **Create new project**.
3. Wait about 2 minutes until the dashboard opens.

**Step 2. Install the database**
1. In the left menu click **SQL Editor**, then **New query**.
2. On your computer, open `database/mwave_all.sql` in Notepad. Press Ctrl+A, then Ctrl+C.
3. Paste it into the Supabase editor (Ctrl+V) and click **Run**.
4. If a box warns about "destructive operations", click **Run this query**. (It only deletes our own old tables, so it is safe.)
5. You should see **Success**. Done: all 14 tables, rules, reports and sample data are now installed.

**Step 3. Run the two tests (to prove it works)**
1. New query. Open `database/tests/test_1_rules.sql`, copy everything, paste, **Run**.
   You should see a table with **17 rows, all saying PASS**.
2. Run `database/mwave_all.sql` again (as in Step 2). This puts the sample data back to fresh.
3. New query. Open `database/tests/test_2_security.sql`, copy, paste, **Run**.
   You should see **48 rows, all saying PASS**.
4. Run `database/mwave_all.sql` **one last time** to clear the test data.
   (Every time you run it, it wipes and rebuilds, so do this before you link logins in Part 2.)

---

## PART 2: Connect the website

**Step 4. Copy your two keys into the website**
1. In Supabase click the **gear icon (Project Settings)**, then **API**.
2. Copy the **Project URL** and the **anon public** key.
3. Open `frontend/config.js` in Notepad. Replace `YOUR-PROJECT-ID...` with the URL and `YOUR-ANON-PUBLIC-KEY` with the key. Save.
   (Never use the `service_role` key here. It is secret.)
   **Heads-up:** Supabase sometimes renames things in its dashboard. If you only see a "publishable" key, look for a tab called
   **Legacy API keys** and copy the **anon** key from there. That is the long key starting with `eyJ`, which is what this website was tested with.

**Step 5. Make 4 test users (one for each role)**
1. In Supabase click **Authentication**, then **Users**, then **Add user**, then **Create new user**.
2. Make these four, with any password you will remember (for example `Test1234!`), and **tick "Auto Confirm User"** each time:

   | Email | This person is the... |
   |---|---|
   | household@test.com | household (Ali Raza) |
   | driver@test.com | driver (Kamran Driver) |
   | operator@test.com | station operator (Station Op 1) |
   | regulator@test.com | regulator |

3. Each user has a long ID called **UID**. Click the user and copy it. You need all four.

**Step 6. Link each user to their role**
1. Go to **SQL Editor**, then **New query**. Paste this, but replace each `PASTE-UID-HERE` with the matching UID from Step 5:

```sql
update profiles set user_id = 'PASTE-UID-HERE' where full_name = 'Ali Raza';
update profiles set user_id = 'PASTE-UID-HERE' where full_name = 'Kamran Driver';
update profiles set user_id = 'PASTE-UID-HERE' where full_name = 'Station Op 1';
update profiles set user_id = 'PASTE-UID-HERE' where full_name = 'Regulator';
```
2. Click **Run**. Each line should say it updated 1 row.

**Step 7. Open the website**
1. Open a terminal (Windows: search "cmd"). Go into the website folder, for example:
   `cd Downloads\M-WAVE\frontend`
2. Type: `python -m http.server 8000`   (on Windows, if that fails: `py -m http.server 8000`)
3. In Chrome open **http://localhost:8000**
4. Log in with `household@test.com` and your password. You should see the quota bar and a "Book a tanker" box.

---

## PART 3: Try the whole flow (this is your demo)

Use a normal window plus an Incognito window, so two people can be logged in at once.

1. **Household:** type `4000` and click **Book tanker**. The quota bar moves.
2. **Household:** type `7000` and book. It is **rejected** (over the monthly limit).
3. **Operator** (`operator@test.com`): type `4000` in the meter box, click **Record fill**, then **Dispatch**.
4. **Household:** click **Get OTP**. A 6-digit code appears (shown only once).
5. **Driver** (`driver@test.com`): type `3950`, click **Mark delivered**. Enter a wrong code (it says wrong), then the real code. The order becomes **VERIFIED**.
6. **Household:** rate the delivery 5 and click **History** to see every step.
7. **Operator:** make another booking as household, then record a meter reading **bigger than the tanker size** (for example `9000`).
8. **Regulator** (`regulator@test.com`): the red **fraud flag** is there. Click **Refresh reports** to see the reports.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| Website says "Almost ready" | You have not saved your keys in `frontend/config.js` (Step 4). |
| "Could not load supabase-js" | No internet. The site loads one library from the web. |
| Every button gives a "permission" or "Invalid API key" error | You pasted the wrong key. Use the long `eyJ...` **anon** key (see the heads-up in Step 4). |
| Login says "Invalid login credentials" | Wrong email or password, or you forgot to tick "Auto Confirm User". Delete the user and add again. |
| "Login not linked yet" after login | Step 6 was skipped, or you re-ran `mwave_all.sql` afterwards. Redo Step 6. |
| Nothing happens on a button | Press F12 in Chrome, click **Console**, and read the red message. |
| You want to start over | Run `database/mwave_all.sql` again, then redo Step 6. |
| Supabase project is "paused" | Free projects pause after about a week idle. Click **Restore** and wait a minute. Do this the day before your demo. |

---

## What is still left for you to do
- Draw the **ER diagram** (use https://erdplus.com, table list is in `README_technical.md`).
- Do the **EXPLAIN ANALYZE** slide: the file `database/07_indexes_for_profiling.sql` is for this (needs thousands of sample orders to show a difference).
- Update the proposal's Tools row and write the report.
