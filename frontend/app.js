// M-WAVE front end: screens. All database calls go through api.js.
(function () {
  'use strict';
  const A = window.MwaveApi;
  const cfg = window.MWAVE_CONFIG || {};
  const view = document.getElementById('view');
  const flashEl = document.getElementById('flash');
  const whoEl = document.getElementById('who');

  let sb = null, user = null, profile = null, rtChannel = null;
  const OTP_KEY = 'mwave_otp';
  const loadOtp = () => { try { return JSON.parse(sessionStorage.getItem(OTP_KEY)); } catch { return null; } };
  const setOtp = (v) => { state.otp = v; if (v) sessionStorage.setItem(OTP_KEY, JSON.stringify(v)); else sessionStorage.removeItem(OTP_KEY); };
  const state = { otp: loadOtp(), historyFor: null, tankers: {} };
  let flashTimer = null;

  // ---------- small helpers ----------
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (n) => Number(n).toLocaleString('en-US');
  const money = (n) => (n == null ? '-' : Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
  const when = (t) => (t ? new Date(t).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : '-');
  const badge = (s) => `<span class="badge s-${esc(s)}">${esc(s)}</span>`;
  const payBadge = (o) => o.payment_status === 'PAID'
    ? `<span class="ok">Paid (${money(o.amount_paid)})</span>`
    : o.payment_status === 'DISPUTED'
      ? `<span class="bad">Disputed (${money(o.amount_paid)})</span>`
      : '<span class="muted">Unpaid</span>';
  const card = (label, value, sub) =>
    `<div class="card"><div class="label">${esc(label)}</div><div class="value">${value}</div>${sub ? `<div class="sub">${sub}</div>` : ''}</div>`;
  const table = (head, rows, empty) => rows.length
    ? `<div class="tablewrap"><table><thead><tr>${head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>`
    : `<div class="panel muted">${esc(empty || 'Nothing to show yet.')}</div>`;

  function flash(msg, type) {
    clearTimeout(flashTimer);
    flashEl.innerHTML = `<div class="msg ${type === 'err' ? 'err' : 'ok'}">${esc(msg)}</div>`;
    if (type !== 'err') flashTimer = setTimeout(() => { flashEl.innerHTML = ''; }, 8000);
  }

  // run an action, show the result, then reload the current screen
  async function run(fn, okMsg) {
    try {
      const r = await fn();
      const m = okMsg ? okMsg(r) : null;
      if (m) flash(m, 'ok'); else flashEl.innerHTML = '';
    } catch (e) {
      flash(e.message || 'Something went wrong', 'err');
    }
    await refresh();
  }

  // ---------- login / logout ----------
  function showSetup() {
    view.innerHTML = `<div class="panel"><h2>Almost ready</h2>
      <p>Open <code>config.js</code> and paste your Supabase <strong>Project URL</strong> and <strong>anon public key</strong>
      (Supabase dashboard &gt; Project Settings &gt; API), then reload this page.</p></div>`;
  }

  function showLogin(msg) {
    whoEl.innerHTML = '';
    view.innerHTML = `<div class="panel loginbox">
      <h2 id="auth-title">Sign in</h2>
      <div id="signup-fields" style="display:none">
        <label for="fname">Full Name</label><input id="fname" class="wide" type="text" autocomplete="name">
        <label for="fphone">Phone</label><input id="fphone" class="wide" type="tel" autocomplete="tel">
        <label for="frole">Role</label>
        <select id="frole" class="wide" style="margin-bottom:10px">
          <option value="household">Household</option>
          <option value="driver">Driver</option>
          <option value="operator">Station Operator</option>
          <option value="regulator">Regulator</option>
        </select>
      </div>
      <label for="em">Email</label><input id="em" class="wide" type="email" autocomplete="username">
      <label for="pw">Password</label><input id="pw" class="wide" type="password" autocomplete="current-password">
      <p class="row" style="margin-top:14px">
        <button id="auth-btn">Sign in</button>
        <button class="ghost" id="toggle-auth">Create account</button>
      </p></div>`;

    if (msg) flash(msg, 'err');
    let isSignup = false;

    document.getElementById('toggle-auth').onclick = () => {
      isSignup = !isSignup;
      document.getElementById('auth-title').innerText = isSignup ? 'Create account' : 'Sign in';
      document.getElementById('auth-btn').innerText = isSignup ? 'Register' : 'Sign in';
      document.getElementById('toggle-auth').innerText = isSignup ? 'Back to sign in' : 'Create account';
      document.getElementById('signup-fields').style.display = isSignup ? 'block' : 'none';
      flashEl.innerHTML = '';
    };

    const go = async () => {
      const email = document.getElementById('em').value.trim();
      const password = document.getElementById('pw').value;
      if (!email || !password) { flash('Enter email and password.', 'err'); return; }

      if (isSignup) {
        const full_name = document.getElementById('fname').value.trim() || 'New User';
        const phone = document.getElementById('fphone').value.trim() || '0300-0000000';
        const role = document.getElementById('frole').value;
        const { data, error } = await sb.auth.signUp({
          email,
          password,
          options: { data: { full_name, phone, role } }
        });
        if (error) { flash(error.message, 'err'); return; }
        flash('Account created successfully! You are now signed in.', 'ok');
        if (data.user) await start(data.user);
      } else {
        const { error } = await sb.auth.signInWithPassword({ email, password });
        if (error) { flash(error.message, 'err'); return; }
        flashEl.innerHTML = '';
        const { data } = await sb.auth.getUser();
        await start(data.user);
      }
    };

    document.getElementById('auth-btn').onclick = go;
    document.getElementById('pw').onkeydown = (e) => { if (e.key === 'Enter') go(); };
  }

  async function logout() {
    if (rtChannel) { sb.removeChannel(rtChannel); rtChannel = null; }
    await sb.auth.signOut();
    user = profile = null; setOtp(null); state.historyFor = null;
    flashEl.innerHTML = '';
    showLogin();
  }

  async function start(u) {
    user = u;
    try { profile = await A.getProfile(sb, user.id); }
    catch (e) { showLogin(e.message); return; }
    if (!profile) {
      whoEl.innerHTML = '<button class="ghost small" id="lo" style="color:#fff;border-color:#ffffff66">Log out</button>';
      document.getElementById('lo').onclick = logout;
      view.innerHTML = `<div class="panel"><h2>Login not linked yet</h2>
        <p>You are signed in, but this login is not linked to an M-WAVE profile. Ask your admin to run, in the Supabase SQL Editor:</p>
        <p><code>update profiles set user_id = '${esc(user.id)}' where full_name = 'YOUR NAME';</code></p></div>`;
      return;
    }
    whoEl.innerHTML = `<span>${esc(profile.full_name)}</span><span class="role">${esc(profile.role)}</span>
      <button class="ghost small" id="lo" style="color:#fff;border-color:#ffffff66">Log out</button>`;
    document.getElementById('lo').onclick = logout;
    subscribeRealtime();
    await refresh();
  }

  function subscribeRealtime() {
    if (rtChannel) sb.removeChannel(rtChannel);
    rtChannel = sb.channel('mwave-live')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'order_status_history' }, (p) => {
        const r = p.new;
        if (user && r.changed_by === user.id) return;
        flash(`Order #${r.order_id} is now ${r.new_status}.`, 'ok');
        refresh();
      })
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'fraud_flags' }, (p) => {
        const f = p.new;
        flash(`New fraud flag on order #${f.order_id}: ${f.flag_type}`, 'err');
        refresh();
      })
      .subscribe();
  }

  async function refresh() {
    if (!profile) return;
    try {
      const v = { household: viewHousehold, driver: viewDriver, operator: viewOperator, regulator: viewRegulator }[profile.role];
      await v();
    } catch (e) { flash(e.message, 'err'); }
  }

  // ---------- household ----------
  async function viewHousehold() {
    const [ov, orders] = await Promise.all([A.householdOverview(sb, user.id), A.listOrders(sb)]);
    if (!ov) { view.innerHTML = '<div class="panel">No household is linked to your login.</div>'; return; }
    state.hh = ov;
    if (state.otp) {
      const o = orders.find((x) => x.order_id === state.otp.order);
      const expired = o && o.otp_expires_at && new Date(o.otp_expires_at) <= new Date();
      if (!o || !['DISPATCHED', 'DELIVERED'].includes(o.status) || (o.otp_attempts || 0) >= 3 || expired) setOtp(null);
    }
    const pct = Math.min(100, Math.round((ov.used / ov.quota) * 100));
    const left = Math.max(0, ov.quota - ov.used);

    const rows = orders.map((o) => {
      let act = '';
      if (o.status === 'WAITING' || o.status === 'BOOKED') {
        act += `<button class="small danger" data-act="cancel" data-order="${o.order_id}">Cancel</button>`;
      }
      if (o.status === 'DISPATCHED' || o.status === 'DELIVERED') {
        if ((o.otp_attempts || 0) >= 3) {
          act += '<span class="bad">OTP locked</span>';
        } else if (o.otp_expires_at) {
          const expired = new Date(o.otp_expires_at) <= new Date();
          act += expired
            ? '<span class="bad">OTP expired</span>'
            : '<span class="muted">OTP issued</span>';
          act += `<button class="small ghost" data-act="otp" data-order="${o.order_id}">New OTP</button>`;
        } else {
          act += `<button class="small" data-act="otp" data-order="${o.order_id}">Get OTP</button>`;
        }
      }
      if ((o.status === 'DELIVERED' || o.status === 'VERIFIED') && o.payment_status === 'UNPAID') {
        act += `<input id="pay${o.order_id}" type="number" min="0" step="0.01" value="${o.price == null ? '' : o.price}" style="width:95px" aria-label="Amount paid">
                <button class="small" data-act="pay" data-order="${o.order_id}">Confirm paid</button>`;
      }
      if (o.status === 'VERIFIED' && o.household_rating == null) {
        act += `<select id="r${o.order_id}" aria-label="Rating">${[5, 4, 3, 2, 1].map((n) => `<option>${n}</option>`).join('')}</select>
                <button class="small" data-act="rate" data-order="${o.order_id}">Rate</button>`;
      }
      if (o.household_rating != null) act += `<span class="muted">Rated ${o.household_rating}/5</span>`;
      act += `<button class="small ghost" data-act="history" data-order="${o.order_id}">History</button>`;
      return `<tr><td>#${o.order_id}</td><td>${num(o.volume_liters)} L</td><td>${money(o.price)}</td><td>${payBadge(o)}</td><td>${badge(o.status)}</td>
        <td>${when(o.booked_at)}</td><td class="actions"><div class="row">${act}</div></td></tr>`;
    });

    view.innerHTML = `
      <h2>My water quota</h2>
      <div class="grid">
        ${card('Property category', esc(ov.category), esc(ov.address))}
        ${card('Used this month', `${num(ov.used)} L`, `of ${num(ov.quota)} L monthly quota`)}
        ${card('Remaining', `${num(left)} L`, `<div class="bar ${pct >= 90 ? 'hot' : ''}"><span style="width:${pct}%"></span></div>`)}
        ${card('Official price cap', ov.price_cap == null ? '-' : money(ov.price_cap), 'per 1000 L, set by the regulator')}
      </div>

      <h2>Book a tanker</h2>
      <div class="panel"><div class="row">
        <input id="vol" type="number" min="1" step="500" placeholder="Liters" aria-label="Liters">
        <button data-act="book">Book tanker</button>
        <span class="muted">If no tanker is free right now, your order waits in the queue and is assigned automatically.</span>
      </div></div>
      ${state.otp ? `<div class="otpbox"><div class="muted">Delivery code for order #${state.otp.order}. Valid for 30 min. Give it to the driver only when the water has been delivered. If lost, click New OTP.</div>
        <div class="otpcode">${esc(state.otp.code)}</div><button class="small ghost" data-act="hideotp">Hide</button></div>` : ''}

      <h2>My orders</h2>
      ${table(['Order', 'Volume', 'Price', 'Payment', 'Status', 'Booked', 'Actions'], rows, 'You have no orders yet.')}
      <div id="history"></div>`;
    if (state.historyFor) await showHistory(state.historyFor);
  }

  async function showHistory(orderId) {
    state.historyFor = orderId;
    const el = document.getElementById('history');
    if (!el) return;
    const h = await A.orderHistory(sb, orderId);
    el.innerHTML = `<h2>History of order #${orderId}</h2><div class="panel"><ol class="timeline">${h.map((x) =>
      `<li>${x.old_status ? badge(x.old_status) + ' &rarr; ' : ''}${badge(x.new_status)} <span class="muted">${when(x.changed_at)}</span></li>`).join('')}</ol></div>`;
  }

  // ---------- driver ----------
  async function viewDriver() {
    const [score, orders, pens] = await Promise.all([A.driverScore(sb), A.listOrders(sb), A.myPenalties(sb)]);
    const hh = await A.householdsByIds(sb, [...new Set(orders.map((o) => o.household_id))]);
    const addr = Object.fromEntries(hh.map((h) => [h.household_id, h.address]));

    const rows = orders.map((o) => {
      let act = '<span class="muted">-</span>';
      if (o.status === 'BOOKED' || o.status === 'FILLED') {
        act = `<div class="row"><span class="muted">Waiting for station</span>
          <button class="small danger" data-act="breakdown" data-order="${o.order_id}">Breakdown</button></div>`;
      }
      if (o.status === 'DISPATCHED') {
        act = `<div class="row"><input id="d${o.order_id}" type="number" min="0" value="${o.volume_liters}" aria-label="Liters delivered">
          <button class="small" data-act="deliver" data-order="${o.order_id}">Mark delivered</button>
          <button class="small danger" data-act="breakdown" data-order="${o.order_id}">Breakdown</button></div>`;
      }
      if (o.status === 'DELIVERED') {
        act = (o.otp_attempts || 0) >= 3
          ? '<span class="bad">Locked (too many tries)</span>'
          : `<div class="row"><input id="p${o.order_id}" inputmode="numeric" maxlength="6" placeholder="6-digit code" style="width:130px" aria-label="OTP">
          <button class="small" data-act="verify" data-order="${o.order_id}">Verify</button></div>`;
      }
      return `<tr><td>#${o.order_id}</td><td>${esc(addr[o.household_id] || '-')}</td><td>${num(o.volume_liters)} L</td>
        <td>${badge(o.status)}</td><td class="actions">${act}</td></tr>`;
    });
    const prow = pens.map((p) => `<tr><td>#${p.order_id}</td><td>${esc(p.reason)}</td><td>${p.points}</td><td>${when(p.created_at)}</td></tr>`);

    view.innerHTML = `
      <h2>My record</h2>
      <div class="grid">
        ${card('Average rating', score && score.avg_rating != null ? `${score.avg_rating} / 5` : 'No ratings yet')}
        ${card('Penalty points', score ? score.penalty_points : 0, 'At 5 points you are blocked from new bookings')}
        ${card('Status', score && score.is_blocked ? '<span class="bad">Blocked</span>' : '<span class="ok">Active</span>')}
      </div>
      <h2>My deliveries</h2>
      ${table(['Order', 'Deliver to', 'Volume', 'Status', 'Action'], rows, 'No orders assigned to you right now.')}
      <h2>My penalties</h2>
      ${table(['Order', 'Reason', 'Points', 'When'], prow, 'No penalties. Keep it up.')}`;
  }

  // ---------- station operator ----------
  async function viewOperator() {
    const [orders, fills, tankers] = await Promise.all([A.listOrders(sb), A.recentFillings(sb), A.getTankers(sb)]);
    state.tankers = Object.fromEntries(tankers.map((t) => [t.tanker_id, t]));
    const rows = orders.map((o) => {
      const t = state.tankers[o.tanker_id];
      let act = '<span class="muted">-</span>';
      if (o.status === 'BOOKED') {
        act = `<div class="row"><input id="m${o.order_id}" type="number" min="1" placeholder="Meter liters" aria-label="Meter reading in liters">
          <button class="small" data-act="fill" data-order="${o.order_id}">Record fill</button></div>`;
      }
      if (o.status === 'FILLED') act = `<button class="small" data-act="dispatch" data-order="${o.order_id}">Dispatch</button>`;
      return `<tr><td>#${o.order_id}</td><td>${t ? esc(t.plate_no) : '-'}</td><td>${t ? num(t.capacity_liters) + ' L' : '-'}</td>
        <td>${num(o.volume_liters)} L</td><td>${badge(o.status)}</td><td class="actions">${act}</td></tr>`;
    });
    const frows = fills.map((f) => `<tr><td>#${f.order_id}</td><td>${num(f.meter_liters)} L</td><td>${num(f.tanker_capacity)} L</td>
      <td>${f.meter_liters > f.tanker_capacity ? '<span class="bad">Over capacity (flagged)</span>' : '<span class="ok">OK</span>'}</td><td>${when(f.recorded_at)}</td></tr>`);
    view.innerHTML = `
      <h2>Orders at my station</h2>
      <p class="muted">Enter the reading from the bulk meter exactly as shown. It is saved in a read-only audit log and checked against the tanker's capacity.</p>
      ${table(['Order', 'Tanker', 'Capacity', 'Ordered', 'Status', 'Action'], rows, 'No orders at your station right now.')}
      <h2>Recent fillings (audit log)</h2>
      ${table(['Order', 'Meter', 'Tanker capacity', 'Check', 'Recorded'], frows, 'No fillings recorded yet.')}`;
  }

  // ---------- regulator ----------
  async function viewRegulator() {
    const [counts, flags, scores, orders, dem, thr, turn, stations, drivers, tankers] = await Promise.all([
      A.orderCounts(sb), A.fraudFlags(sb), A.driverScores(sb), A.listOrders(sb, 30),
      A.reportDemand(sb), A.reportThroughput(sb), A.reportTurnaround(sb),
      A.getStations(sb), A.getDrivers(sb), A.getTankers(sb)]);
    const open = flags.filter((f) => !f.resolved).length;
    const driverMap = Object.fromEntries(drivers.map((d) => [d.driver_id, d]));
    const tankerOpts = (sel) => `<option value="">Unassigned</option>` + tankers.map((t) =>
      `<option value="${t.tanker_id}" ${t.tanker_id === sel ? 'selected' : ''}>#${t.tanker_id} ${esc(t.plate_no)} (${num(t.capacity_liters)} L)</option>`
    ).join('');

    view.innerHTML = `
      <h2>City overview</h2>
      <div class="grid">
        ${card('Waiting for a tanker', counts.WAITING, 'unfulfilled demand')}
        ${card('In progress', counts.BOOKED + counts.FILLED + counts.DISPATCHED + counts.DELIVERED, 'booked to delivered')}
        ${card('Verified deliveries', counts.VERIFIED)}
        ${card('Open fraud flags', open ? `<span class="bad">${open}</span>` : '0')}
      </div>
      <div class="panel row" style="margin-top:12px">
        <button data-act="refreshreports">Refresh reports</button>
        <button class="ghost" data-act="penalize">Penalize unverified deliveries (24 h)</button>
        <span class="muted">Reports are saved snapshots; refresh to include the latest orders.</span>
      </div>

      <h2>Unfulfilled demand by area</h2>
      ${table(['Area', 'Households', 'Waiting orders', 'Waiting liters', 'Demand density'],
        dem.map((r) => `<tr><td>${esc(r.area)}</td><td>${r.households}</td><td>${r.waiting_orders}</td><td>${num(r.waiting_liters)}</td><td>${r.demand_density == null ? '-' : r.demand_density}</td></tr>`))}
      <h2>Filling station throughput</h2>
      ${table(['Station', 'Day', 'Fillings', 'Liters filled'],
        thr.map((r) => `<tr><td>${esc(r.station)}</td><td>${esc(r.day)}</td><td>${r.fillings}</td><td>${num(r.liters_filled)}</td></tr>`), 'No fillings yet. Refresh the reports after a delivery.')}
      <h2>Driver turnaround</h2>
      ${table(['Driver', 'Verified deliveries', 'Avg. booking to verified'],
        turn.map((r) => `<tr><td>${esc(r.driver)}</td><td>${r.verified_deliveries}</td><td>${esc(r.avg_turnaround || '-')}</td></tr>`))}
      <h2>Driver scores &amp; management</h2>
      ${table(['Driver', 'Avg. rating', 'Penalty points', 'Status', 'Tanker', 'Action'],
        scores.map((r) => {
          const d = driverMap[r.driver_id] || {};
          return `<tr><td>${esc(r.driver)}</td><td>${r.avg_rating == null ? '-' : r.avg_rating}</td><td>${r.penalty_points}</td>
            <td>${r.is_blocked ? '<span class="bad">Blocked</span>' : '<span class="ok">Active</span>'}</td>
            <td class="actions"><div class="row"><select data-tanker-for="${r.driver_id}">${tankerOpts(d.tanker_id)}</select>
              <button class="small" data-act="assign-tanker" data-id="${r.driver_id}">Save</button></div></td>
            <td class="actions">${r.is_blocked ? `<button class="small" data-act="unblock-driver" data-id="${r.driver_id}">Unblock</button>` : '<span class="muted">-</span>'}</td></tr>`;
        }))}
      <h2>Onboard driver</h2>
      <div class="panel"><div class="row">
        <input id="drv-email" type="email" placeholder="Registered user email">
        <input id="drv-lic" type="text" placeholder="License no (e.g. KHI-9921)">
        <select id="drv-tanker">${tankerOpts(null)}</select>
        <button data-act="onboard-driver">Promote to driver</button>
      </div></div>
      <h2>Station operators</h2>
      ${table(['Station', 'Current operator ID', 'Assign by email', 'Action'],
        stations.map((s) => `<tr><td>#${s.station_id} ${esc(s.name)}</td><td class="muted">${esc(s.operator_id || 'Unassigned')}</td>
          <td><input data-op-for="${s.station_id}" type="email" placeholder="Registered user email"></td>
          <td class="actions"><button class="small" data-act="assign-op" data-id="${s.station_id}">Assign</button></td></tr>`))}
      <h2>Fraud flags</h2>
      ${table(['Order', 'Type', 'Details', 'When', 'Action'],
        flags.map((f) => `<tr><td>#${f.order_id}</td><td><span class="bad">${esc(f.flag_type)}</span></td><td>${esc(f.details)}</td><td>${when(f.created_at)}</td>
          <td class="actions">${f.resolved ? '<span class="ok">Resolved</span>' : `<button class="small" data-act="resolve-flag" data-id="${f.flag_id}">Resolve</button>`}</td></tr>`), 'No fraud flags. All clear.')}
      <h2>Tanker fleet</h2>
      ${table(['Tanker', 'Capacity', 'Rate / 1000 L', 'Status', 'Action'],
        tankers.map((t) => `<tr><td>#${t.tanker_id} ${esc(t.plate_no)}</td><td>${num(t.capacity_liters)} L</td><td>${money(t.price_per_1000l)}</td>
          <td>${t.status === 'BLOCKED' ? '<span class="bad">BLOCKED</span>' : t.status === 'BUSY' ? '<span class="muted">BUSY</span>' : '<span class="ok">AVAILABLE</span>'}</td>
          <td class="actions">${t.status === 'BLOCKED' ? `<button class="small" data-act="unblock-tanker" data-id="${t.tanker_id}">Mark repaired</button>` : '<span class="muted">-</span>'}</td></tr>`))}
      <h2>Latest orders</h2>
      ${table(['Order', 'Household', 'Tanker', 'Driver', 'Volume', 'Price', 'Payment', 'Status', 'Booked', 'Action'],
        orders.map((o) => `<tr><td>#${o.order_id}</td><td>${o.household_id}</td><td>${o.tanker_id || '-'}</td><td>${o.driver_id || '-'}</td>
          <td>${num(o.volume_liters)} L</td><td>${money(o.price)}</td><td>${payBadge(o)}</td><td>${badge(o.status)}</td><td>${when(o.booked_at)}</td>
          <td class="actions">${['BOOKED', 'FILLED', 'DISPATCHED'].includes(o.status) ? `<button class="small danger" data-act="breakdown" data-order="${o.order_id}">Reassign</button>` : '<span class="muted">-</span>'}</td></tr>`))}`;
  }

  // ---------- click handling (one listener for every button) ----------
  view.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-act]');
    if (!b || b.disabled) return;
    const id = Number(b.dataset.order);
    const val = (prefix) => document.getElementById(prefix + id);
    const int = (el) => (el && el.value !== '' ? parseInt(el.value, 10) : NaN);
    b.disabled = true;
    switch (b.dataset.act) {
      case 'book': {
        const v = parseInt(document.getElementById('vol').value, 10);
        if (!(v > 0)) { flash('Enter how many liters you need.', 'err'); b.disabled = false; return; }
        await run(() => A.placeOrder(sb, state.hh.household_id, v), (oid) => `Order #${oid} placed.`);
        break;
      }
      case 'cancel': await run(() => A.cancelOrder(sb, id), () => `Order #${id} cancelled and your quota was returned.`); break;
      case 'otp': {
        try { setOtp({ order: id, code: await A.getOtp(sb, id) }); flashEl.innerHTML = ''; }
        catch (err) { flash(err.message, 'err'); }
        await refresh(); break;
      }
      case 'hideotp': setOtp(null); await refresh(); break;
      case 'pay': {
        const amt = parseFloat(val('pay').value);
        if (!(amt >= 0)) { flash('Enter the exact amount paid.', 'err'); b.disabled = false; return; }
        await run(() => A.confirmPayment(sb, id, amt), (st) =>
          st === 'DISPUTED'
            ? `Order #${id} payment disputed (exceeds official price). Flagged for regulator.`
            : `Order #${id} payment confirmed.`);
        break;
      }
      case 'rate': await run(() => A.rateOrder(sb, id, int(val('r'))), () => 'Thanks for rating.'); break;
      case 'history': try { await showHistory(id); } catch (err) { flash(err.message, 'err'); } b.disabled = false; break;
      case 'deliver': {
        const n = int(val('d'));
        if (!(n >= 0)) { flash('Enter the liters delivered.', 'err'); b.disabled = false; return; }
        await run(() => A.markDelivered(sb, id, n), () => `Order #${id} marked delivered. Now ask the household for their code.`);
        break;
      }
      case 'verify': {
        const code = (val('p').value || '').trim();
        if (!code) { flash('Enter the 6-digit code from the household.', 'err'); b.disabled = false; return; }
        await run(() => A.verifyOtp(sb, id, code), (r) => ({
          VERIFIED: `Order #${id} verified. Delivery complete.`,
          WRONG_OTP: 'Wrong code. Please try again.',
          LOCKED: 'Too many wrong codes. This order is locked and has been flagged.',
          EXPIRED: 'This code has expired.'
        }[r] || r));
        break;
      }
      case 'fill': {
        const m = int(val('m'));
        if (!(m > 0)) { flash('Enter the meter reading in liters.', 'err'); b.disabled = false; return; }
        await run(() => A.recordFill(sb, id, m), () => `Fill recorded for order #${id}.`);
        break;
      }
      case 'dispatch': await run(() => A.dispatchOrder(sb, id), () => `Order #${id} dispatched.`); break;
      case 'refreshreports': await run(() => A.refreshReports(sb), () => 'Reports refreshed.'); break;
      case 'penalize': await run(() => A.penalizeUnverified(sb, 24), (n) => `${n} unverified delivery(ies) penalized.`); break;
      case 'resolve-flag':
        await run(() => A.adminResolveFraud(sb, Number(b.dataset.id)), () => 'Fraud flag resolved.');
        break;
      case 'breakdown':
        await run(() => A.reportBreakdown(sb, id), (r) =>
          r === 'REASSIGNED'
            ? `Order #${id} reassigned to another available tanker. Broken tanker marked BLOCKED.`
            : `Broken tanker marked BLOCKED. Order #${id} returned to front of queue.`);
        break;
      case 'unblock-driver':
        await run(() => A.adminUnblockDriver(sb, Number(b.dataset.id)), () => 'Driver unblocked and points reset.');
        break;
      case 'unblock-tanker':
        await run(() => A.adminUnblockTanker(sb, Number(b.dataset.id)), (n) =>
          `Tanker marked AVAILABLE.${n ? ` ${n} waiting order(s) auto-assigned.` : ''}`);
        break;
      case 'assign-tanker': {
        const driverId = Number(b.dataset.id);
        const tid = document.querySelector(`[data-tanker-for="${driverId}"]`).value;
        await run(() => A.adminAssignTanker(sb, driverId, tid ? Number(tid) : null), () => 'Tanker updated.');
        break;
      }
      case 'onboard-driver': {
        const email = document.getElementById('drv-email').value.trim();
        const lic = document.getElementById('drv-lic').value.trim();
        const tid = document.getElementById('drv-tanker').value;
        if (!email || !lic) { flash('Enter both email and license number.', 'err'); b.disabled = false; return; }
        await run(() => A.adminOnboardDriver(sb, email, lic, tid ? Number(tid) : null), () => 'Driver onboarded.');
        break;
      }
      case 'assign-op': {
        const stationId = Number(b.dataset.id);
        const email = document.querySelector(`[data-op-for="${stationId}"]`).value.trim();
        if (!email) { flash('Enter the operator email.', 'err'); b.disabled = false; return; }
        await run(() => A.adminAssignOperator(sb, stationId, email), () => 'Station operator assigned.');
        break;
      }
      default: b.disabled = false;
    }
  });

  // ---------- boot ----------
  async function boot() {
    sb = window.MWAVE_SB || null;      // MWAVE_SB lets automated tests inject a client
    if (!sb) {
      if (!cfg.SUPABASE_URL || /YOUR-/.test(cfg.SUPABASE_URL) || /YOUR-/.test(cfg.SUPABASE_ANON_KEY || '')) { showSetup(); return; }
      if (!window.supabase) { view.innerHTML = '<div class="panel bad">Could not load supabase-js. Check your internet connection.</div>'; return; }
      sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
    }
    const { data } = await sb.auth.getSession();
    if (data && data.session) await start(data.session.user); else showLogin();
  }
  boot();
})();