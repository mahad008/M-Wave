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
  const state = { otp: loadOtp(), historyFor: null, tankers: {}, regTab: 'overview' };
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
        <label for="fphone">Phone</label><input id="fphone" class="wide" type="tel" placeholder="0300-1234567" autocomplete="tel">
        <label for="fcnic">CNIC</label><input id="fcnic" class="wide" type="text" placeholder="42101-1234567-1" maxlength="15">
        <p class="muted" style="font-size:12px;margin:6px 0 0">New accounts register as Household. Drivers &amp; Operators are promoted by the Regulator.</p>
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
        const full_name = document.getElementById('fname').value.trim();
        const phone = document.getElementById('fphone').value.trim();
        const cnic = document.getElementById('fcnic').value.trim();
        if (!full_name || !phone) { flash('Enter your full name and phone number.', 'err'); return; }
        if (!/^\d{5}-\d{7}-\d$/.test(cnic)) { flash('Enter CNIC in 42101-1234567-1 format.', 'err'); return; }
        const { data, error } = await sb.auth.signUp({
          email,
          password,
          options: { data: { full_name, phone, cnic } }
        });
        if (error) { flash(error.message, 'err'); return; }
        if (data.session && data.user) {
          flash('Account created! Complete your household details below.', 'ok');
          await start(data.user);
        } else {
          flash('Account created! Check your email to confirm, then sign in.', 'ok');
        }
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
    if (!ov) {
      const [areas, cats] = await Promise.all([A.getAreas(sb), A.getCategories(sb)]);
      view.innerHTML = `<div class="panel loginbox" style="max-width:460px">
        <h2>Complete household registration</h2>
        <p class="muted">Submit your property details once. A Regulator will verify your water bill and activate your monthly quota.</p>
        <label for="hh-area">Area</label>
        <select id="hh-area" class="wide">${areas.map((a) => `<option value="${a.area_id}">${esc(a.name)}${a.zone ? ' (' + esc(a.zone) + ')' : ''}</option>`).join('')}</select>
        <label for="hh-cat">Property Category</label>
        <select id="hh-cat" class="wide">${cats.map((c) => `<option value="${c.category_id}">${esc(c.name)} — ${num(c.monthly_quota_liters)} L/month</option>`).join('')}</select>
        <label for="hh-bill">Water / Utility Bill No.</label>
        <input id="hh-bill" class="wide" type="text" placeholder="e.g. KWSB-904821">
        <label for="hh-addr">Full Address</label>
        <input id="hh-addr" class="wide" type="text" placeholder="House / Flat #, Block, Street">
        <p style="margin-top:14px"><button data-act="register-hh">Submit for approval</button></p>
      </div>`;
      return;
    }
    if (!ov.is_active) {
      view.innerHTML = `<div class="panel">
        <h2>Pending regulator approval</h2>
        <p>Your household registration is under review. You can book tankers as soon as the Regulator approves your account.</p>
        <p class="muted"><strong>Address:</strong> ${esc(ov.address)} &bull; <strong>Category:</strong> ${esc(ov.category)} &bull; <strong>Bill No.:</strong> ${esc(ov.utility_bill_no || '-')}</p>
      </div>`;
      return;
    }
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
    const [counts, flags, scores, orders, dem, thr, turn, stations, drivers, tankers, areas, cats, rates, households, profiles] = await Promise.all([
      A.orderCounts(sb), A.fraudFlags(sb), A.driverScores(sb), A.listOrders(sb, 30),
      A.reportDemand(sb), A.reportThroughput(sb), A.reportTurnaround(sb),
      A.getStations(sb), A.getDrivers(sb), A.getTankers(sb),
      A.getAreas(sb), A.getCategories(sb), A.getPriceRates(sb), A.getHouseholds(sb), A.getProfiles(sb)]);

    const open = flags.filter((f) => !f.resolved).length;
    const pendingHh = households.filter((h) => !h.is_active).length;
    const driverMap = Object.fromEntries(drivers.map((d) => [d.driver_id, d]));
    const areaMap = Object.fromEntries(areas.map((a) => [a.area_id, a]));
    const catMap = Object.fromEntries(cats.map((c) => [c.category_id, c]));
    const profMap = Object.fromEntries(profiles.map((p) => [p.user_id, p]));

    const tankerOpts = (sel) => `<option value="">Unassigned</option>` + tankers.map((t) =>
      `<option value="${t.tanker_id}" ${t.tanker_id === sel ? 'selected' : ''}>#${t.tanker_id} ${esc(t.plate_no)} (${num(t.capacity_liters)} L)</option>`
    ).join('');
    const areaOpts = (sel) => areas.map((a) =>
      `<option value="${a.area_id}" ${a.area_id === sel ? 'selected' : ''}>${esc(a.name)}</option>`
    ).join('');
    const catOpts = (sel) => cats.map((c) =>
      `<option value="${c.category_id}" ${c.category_id === sel ? 'selected' : ''}>${esc(c.name)}</option>`
    ).join('');

    const tab = state.regTab || 'overview';
    const tabsHtml = `<div class="tabs">
      <button class="tab ${tab === 'overview' ? 'active' : ''}" data-act="reg-tab" data-tab="overview">Overview &amp; Orders${open ? ` (${open})` : ''}</button>
      <button class="tab ${tab === 'people' ? 'active' : ''}" data-act="reg-tab" data-tab="people">People &amp; Fleet${pendingHh ? ` (${pendingHh} pending)` : ''}</button>
      <button class="tab ${tab === 'setup' ? 'active' : ''}" data-act="reg-tab" data-tab="setup">Setup &amp; Rates</button>
    </div>`;

    let body = '';
    if (tab === 'overview') {
      body = `
        <h2>City overview</h2>
        <div class="grid">
          ${card('Waiting for a tanker', counts.WAITING, 'unfulfilled demand')}
          ${card('In progress', counts.BOOKED + counts.FILLED + counts.DISPATCHED + counts.DELIVERED, 'booked to delivered')}
          ${card('Verified deliveries', counts.VERIFIED)}
          ${card('Open fraud flags', open ? `<span class="bad">${open}</span>` : '0', pendingHh ? `${pendingHh} household(s) awaiting approval` : '')}
        </div>
        <div class="panel row" style="margin-top:12px">
          <button data-act="refreshreports">Refresh reports</button>
          <button class="ghost" data-act="penalize">Penalize unverified deliveries (24 h)</button>
          <span class="muted">Reports are saved snapshots; refresh to include the latest orders.</span>
        </div>

        <h2>Fraud flags</h2>
        ${table(['Order', 'Type', 'Details', 'When', 'Action'],
          flags.map((f) => `<tr><td>#${f.order_id}</td><td><span class="bad">${esc(f.flag_type)}</span></td><td>${esc(f.details)}</td><td>${when(f.created_at)}</td>
            <td class="actions">${f.resolved ? '<span class="ok">Resolved</span>' : `<button class="small" data-act="resolve-flag" data-id="${f.flag_id}">Resolve</button>`}</td></tr>`), 'No fraud flags. All clear.')}
        <h2>Latest orders</h2>
        ${table(['Order', 'Household', 'Tanker', 'Driver', 'Volume', 'Price', 'Payment', 'Status', 'Booked', 'Action'],
          orders.map((o) => `<tr><td>#${o.order_id}</td><td>${o.household_id}</td><td>${o.tanker_id || '-'}</td><td>${o.driver_id || '-'}</td>
            <td>${num(o.volume_liters)} L</td><td>${money(o.price)}</td><td>${payBadge(o)}</td><td>${badge(o.status)}</td><td>${when(o.booked_at)}</td>
            <td class="actions">${['BOOKED', 'FILLED', 'DISPATCHED'].includes(o.status) ? `<button class="small danger" data-act="breakdown" data-order="${o.order_id}">Reassign</button>` : '<span class="muted">-</span>'}</td></tr>`))}
        <h2>Unfulfilled demand by area</h2>
        ${table(['Area', 'Households', 'Waiting orders', 'Waiting liters', 'Demand density'],
          dem.map((r) => `<tr><td>${esc(r.area)}</td><td>${r.households}</td><td>${r.waiting_orders}</td><td>${num(r.waiting_liters)}</td><td>${r.demand_density == null ? '-' : r.demand_density}</td></tr>`))}
        <h2>Filling station throughput</h2>
        ${table(['Station', 'Day', 'Fillings', 'Liters filled'],
          thr.map((r) => `<tr><td>${esc(r.station)}</td><td>${esc(r.day)}</td><td>${r.fillings}</td><td>${num(r.liters_filled)}</td></tr>`), 'No fillings yet. Refresh the reports after a delivery.')}
        <h2>Driver turnaround</h2>
        ${table(['Driver', 'Verified deliveries', 'Avg. booking to verified'],
          turn.map((r) => `<tr><td>${esc(r.driver)}</td><td>${r.verified_deliveries}</td><td>${esc(r.avg_turnaround || '-')}</td></tr>`))}`;
    } else if (tab === 'people') {
      body = `
        <h2>Households (approvals &amp; categories)</h2>
        ${table(['Household', 'Owner / CNIC', 'Area &amp; Address', 'Bill No.', 'Category', 'Status', 'Action'],
          households.map((h) => {
            const p = profMap[h.user_id] || {};
            const a = areaMap[h.area_id];
            return `<tr>
              <td>#${h.household_id}</td>
              <td>${esc(p.full_name || '-')}<div class="muted" style="font-size:12px">${esc(p.cnic || 'No CNIC')}</div></td>
              <td>${esc(a ? a.name : '-')}<div class="muted" style="font-size:12px">${esc(h.address)}</div></td>
              <td>${esc(h.utility_bill_no || '-')}</td>
              <td><select data-hh-cat="${h.household_id}">${catOpts(h.category_id)}</select></td>
              <td>${h.is_active ? '<span class="ok">Active</span>' : '<span class="bad">Pending</span>'}</td>
              <td class="actions"><div class="row">
                <button class="small ${h.is_active ? 'danger' : ''}" data-act="hh-status" data-id="${h.household_id}" data-active="${h.is_active ? '0' : '1'}">${h.is_active ? 'Deactivate' : 'Approve'}</button>
                ${h.is_active ? `<button class="small ghost" data-act="hh-status" data-id="${h.household_id}" data-active="1">Save cat</button>` : ''}
              </div></td></tr>`;
          }))}

        <h2>Onboard driver</h2>
        <div class="panel"><div class="row">
          <input id="drv-email" type="email" placeholder="Registered user email">
          <input id="drv-lic" type="text" placeholder="License no (e.g. KHI-9921)">
          <select id="drv-tanker">${tankerOpts(null)}</select>
          <button data-act="onboard-driver">Promote to driver</button>
        </div></div>

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

        <h2>Tanker fleet</h2>
        <div class="panel" style="margin-bottom:12px"><div class="row">
          <input id="tk-plate" type="text" placeholder="Plate no (e.g. KHI-2004)">
          <input id="tk-cap" type="number" min="1" step="500" placeholder="Capacity (L)">
          <input id="tk-price" type="number" min="0" step="10" placeholder="Rate / 1000 L">
          <button data-act="add-tanker">Add tanker</button>
        </div></div>
        ${table(['ID', 'Plate No.', 'Capacity (L)', 'Rate / 1000 L', 'Status', 'Action'],
          tankers.map((t) => {
            const busy = t.status === 'BUSY';
            return `<tr>
              <td>#${t.tanker_id}</td>
              <td><input data-tk-plate="${t.tanker_id}" type="text" value="${esc(t.plate_no)}" style="width:120px" ${busy ? 'disabled' : ''}></td>
              <td><input data-tk-cap="${t.tanker_id}" type="number" min="1" value="${t.capacity_liters}" style="width:105px" ${busy ? 'disabled' : ''}></td>
              <td><input data-tk-price="${t.tanker_id}" type="number" min="0" step="0.01" value="${t.price_per_1000l}" style="width:105px" ${busy ? 'disabled' : ''}></td>
              <td>${t.status === 'BLOCKED' ? '<span class="bad">BLOCKED</span>' : busy ? '<span class="muted">BUSY</span>' : '<span class="ok">AVAILABLE</span>'}</td>
              <td class="actions"><div class="row">
                ${busy ? '<span class="muted">On active order</span>' : `<button class="small ghost" data-act="save-tanker" data-id="${t.tanker_id}">Save</button>`}
                ${t.status === 'BLOCKED' ? `<button class="small" data-act="unblock-tanker" data-id="${t.tanker_id}">Mark repaired</button>` : ''}
                ${t.status === 'AVAILABLE' ? `<button class="small danger" data-act="block-tanker" data-id="${t.tanker_id}">Retire</button>` : ''}
              </div></td></tr>`;
          }))}`;
    } else {
      const nowMs = Date.now();
      const activeRateIds = new Set();
      for (const c of cats) {
        const cur = rates.find((r) => r.category_id === c.category_id && new Date(r.effective_from).getTime() <= nowMs);
        if (cur) activeRateIds.add(cur.rate_id);
      }

      body = `
        <h2>Areas</h2>
        <div class="panel" style="margin-bottom:12px"><div class="row">
          <input id="ar-name" type="text" placeholder="Area name (e.g. Clifton)">
          <input id="ar-zone" type="text" placeholder="Zone (e.g. South)">
          <button data-act="add-area">Add area</button>
        </div></div>
        ${table(['ID', 'Name', 'Zone', 'Action'],
          areas.map((a) => `<tr><td>#${a.area_id}</td>
            <td><input data-ar-name="${a.area_id}" type="text" value="${esc(a.name)}"></td>
            <td><input data-ar-zone="${a.area_id}" type="text" value="${esc(a.zone || '')}"></td>
            <td class="actions"><button class="small" data-act="save-area" data-id="${a.area_id}">Save</button></td></tr>`))}

        <h2>Property categories &amp; monthly quotas</h2>
        <div class="panel" style="margin-bottom:12px"><div class="row">
          <input id="cat-name" type="text" placeholder="Category name">
          <input id="cat-quota" type="number" min="1" step="500" placeholder="Monthly quota (L)">
          <button data-act="add-cat">Add category</button>
        </div></div>
        ${table(['ID', 'Category', 'Monthly quota (L)', 'Action'],
          cats.map((c) => `<tr><td>#${c.category_id}</td>
            <td><input data-cat-name="${c.category_id}" type="text" value="${esc(c.name)}"></td>
            <td><input data-cat-quota="${c.category_id}" type="number" min="1" value="${c.monthly_quota_liters}"></td>
            <td class="actions"><button class="small" data-act="save-cat" data-id="${c.category_id}">Save</button></td></tr>`))}

        <h2>Official price caps (append-only history)</h2>
        <div class="panel" style="margin-bottom:12px"><div class="row">
          <select id="rt-cat">${catOpts(null)}</select>
          <input id="rt-price" type="number" min="1" step="10" placeholder="Max / 1000 L">
          <input id="rt-from" type="datetime-local" title="Effective from (leave blank for now)">
          <button data-act="add-rate">Add price cap</button>
        </div></div>
        ${table(['Category', 'Max / 1000 L', 'Effective from', 'State'],
          rates.map((r) => {
            const c = catMap[r.category_id];
            const isFuture = new Date(r.effective_from).getTime() > nowMs;
            const st = activeRateIds.has(r.rate_id)
              ? '<span class="ok">Active</span>'
              : isFuture ? '<span class="badge s-BOOKED">Scheduled</span>' : '<span class="muted">Past</span>';
            return `<tr><td>${esc(c ? c.name : '#' + r.category_id)}</td><td>${money(r.max_price_per_1000l)}</td><td>${when(r.effective_from)}</td><td>${st}</td></tr>`;
          }))}

        <h2>Filling stations &amp; operators</h2>
        <div class="panel" style="margin-bottom:12px"><div class="row">
          <input id="st-name" type="text" placeholder="Station name (e.g. Clifton Hydrant)">
          <select id="st-area">${areaOpts(null)}</select>
          <button data-act="add-station">Add station</button>
        </div></div>
        ${table(['ID', 'Station Name', 'Area', 'Current operator', 'Assign operator by email', 'Action'],
          stations.map((s) => `<tr>
            <td>#${s.station_id}</td>
            <td><input data-st-name="${s.station_id}" type="text" value="${esc(s.name)}" style="width:155px"></td>
            <td><select data-st-area="${s.station_id}">${areaOpts(s.area_id)}</select></td>
            <td class="muted" style="font-size:12px">${esc(profMap[s.operator_id] ? profMap[s.operator_id].full_name : (s.operator_id || 'Unassigned'))}</td>
            <td><input data-op-for="${s.station_id}" type="email" placeholder="User email" style="width:165px"></td>
            <td class="actions"><div class="row">
              <button class="small ghost" data-act="save-station" data-id="${s.station_id}">Save</button>
              <button class="small" data-act="assign-op" data-id="${s.station_id}">Assign op</button>
            </div></td></tr>`))}`;
    }

    view.innerHTML = tabsHtml + body;
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
      case 'reg-tab':
        state.regTab = b.dataset.tab;
        await refresh();
        break;
      case 'register-hh': {
        const areaId = Number(document.getElementById('hh-area').value);
        const catId = Number(document.getElementById('hh-cat').value);
        const bill = document.getElementById('hh-bill').value.trim();
        const addr = document.getElementById('hh-addr').value.trim();
        if (!bill || !addr) { flash('Enter both Water Bill No. and full address.', 'err'); b.disabled = false; return; }
        await run(() => A.registerHousehold(sb, areaId, catId, addr, bill), () => 'Household submitted for regulator approval.');
        break;
      }
      case 'hh-status': {
        const hhId = Number(b.dataset.id);
        const active = b.dataset.active === '1';
        const catId = Number(document.querySelector(`[data-hh-cat="${hhId}"]`).value);
        await run(() => A.adminSetHouseholdStatus(sb, hhId, active, catId), () => active ? `Household #${hhId} active.` : `Household #${hhId} deactivated.`);
        break;
      }
      case 'add-tanker': {
        const plate = document.getElementById('tk-plate').value.trim();
        const cap = parseInt(document.getElementById('tk-cap').value, 10);
        const price = parseFloat(document.getElementById('tk-price').value);
        if (!plate || !(cap > 0) || !(price >= 0)) { flash('Enter plate no., capacity, and rate.', 'err'); b.disabled = false; return; }
        await run(() => A.adminSaveTanker(sb, plate, cap, price, null), () => 'Tanker added.');
        break;
      }
      case 'save-tanker': {
        const tid = Number(b.dataset.id);
        const plate = document.querySelector(`[data-tk-plate="${tid}"]`).value.trim();
        const cap = parseInt(document.querySelector(`[data-tk-cap="${tid}"]`).value, 10);
        const price = parseFloat(document.querySelector(`[data-tk-price="${tid}"]`).value);
        if (!plate || !(cap > 0) || !(price >= 0)) { flash('Enter valid plate, capacity, and rate.', 'err'); b.disabled = false; return; }
        await run(() => A.adminSaveTanker(sb, plate, cap, price, tid), () => `Tanker #${tid} updated.`);
        break;
      }
      case 'block-tanker':
        await run(() => A.adminBlockTanker(sb, Number(b.dataset.id)), () => 'Tanker retired (marked BLOCKED).');
        break;
      case 'add-area': {
        const name = document.getElementById('ar-name').value.trim();
        const zone = document.getElementById('ar-zone').value.trim();
        if (!name) { flash('Enter an area name.', 'err'); b.disabled = false; return; }
        await run(() => A.adminSaveArea(sb, name, zone, null), () => 'Area added.');
        break;
      }
      case 'save-area': {
        const aid = Number(b.dataset.id);
        const name = document.querySelector(`[data-ar-name="${aid}"]`).value.trim();
        const zone = document.querySelector(`[data-ar-zone="${aid}"]`).value.trim();
        if (!name) { flash('Area name is required.', 'err'); b.disabled = false; return; }
        await run(() => A.adminSaveArea(sb, name, zone, aid), () => `Area #${aid} updated.`);
        break;
      }
      case 'add-cat': {
        const name = document.getElementById('cat-name').value.trim();
        const quota = parseInt(document.getElementById('cat-quota').value, 10);
        if (!name || !(quota > 0)) { flash('Enter category name and monthly quota.', 'err'); b.disabled = false; return; }
        await run(() => A.adminSaveCategory(sb, name, quota, null), () => 'Category added.');
        break;
      }
      case 'save-cat': {
        const cid = Number(b.dataset.id);
        const name = document.querySelector(`[data-cat-name="${cid}"]`).value.trim();
        const quota = parseInt(document.querySelector(`[data-cat-quota="${cid}"]`).value, 10);
        if (!name || !(quota > 0)) { flash('Enter valid category name and quota.', 'err'); b.disabled = false; return; }
        await run(() => A.adminSaveCategory(sb, name, quota, cid), () => `Category #${cid} updated.`);
        break;
      }
      case 'add-rate': {
        const cid = Number(document.getElementById('rt-cat').value);
        const price = parseFloat(document.getElementById('rt-price').value);
        const fromVal = document.getElementById('rt-from').value;
        if (!(price > 0)) { flash('Enter a price cap above 0.', 'err'); b.disabled = false; return; }
        const effFrom = fromVal ? new Date(fromVal).toISOString() : null;
        await run(() => A.adminAddPriceRate(sb, cid, price, effFrom), () => 'Price cap saved.');
        break;
      }
      case 'add-station': {
        const name = document.getElementById('st-name').value.trim();
        const aid = Number(document.getElementById('st-area').value);
        if (!name) { flash('Enter a station name.', 'err'); b.disabled = false; return; }
        await run(() => A.adminSaveStation(sb, name, aid, null), () => 'Station added.');
        break;
      }
      case 'save-station': {
        const sid = Number(b.dataset.id);
        const name = document.querySelector(`[data-st-name="${sid}"]`).value.trim();
        const aid = Number(document.querySelector(`[data-st-area="${sid}"]`).value);
        if (!name) { flash('Station name is required.', 'err'); b.disabled = false; return; }
        await run(() => A.adminSaveStation(sb, name, aid, sid), () => `Station #${sid} updated.`);
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