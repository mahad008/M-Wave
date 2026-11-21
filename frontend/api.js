// M-WAVE front end: data layer. Every database call lives here (no HTML in this file).
// Works in the browser (window.MwaveApi) and in Node for testing (module.exports).
(function (root) {
  'use strict';

  // orders has no "select *": the otp_hash column is blocked by the database on purpose.
  const ORDER_COLS = 'order_id,household_id,tanker_id,driver_id,station_id,volume_liters,price,status,' +
    'amount_paid,payment_status,' +
    'otp_attempts,otp_expires_at,otp_verified,delivered_liters,household_rating,' +
    'booked_at,filled_at,dispatched_at,delivered_at,verified_at';

  function unwrap(res) {
    if (res.error) throw new Error(res.error.message);
    return res.data;
  }
  const rpc = async (sb, fn, args) => unwrap(await sb.rpc(fn, args));

  const api = {
    ORDER_COLS,

    // ---------- common ----------
    async getProfile(sb, uid) {
      return unwrap(await sb.from('profiles').select('user_id,role,full_name,phone,cnic').eq('user_id', uid).maybeSingle());
    },
    async listOrders(sb, limit = 50) {
      return unwrap(await sb.from('orders').select(ORDER_COLS).order('order_id', { ascending: false }).limit(limit));
    },
    async orderHistory(sb, orderId) {
      return unwrap(await sb.from('order_status_history').select('old_status,new_status,changed_at')
        .eq('order_id', orderId).order('history_id', { ascending: true }));
    },
    async getTankers(sb) {
      return unwrap(await sb.from('tankers').select('tanker_id,plate_no,capacity_liters,price_per_1000l,status').order('tanker_id'));
    },
    async getAreas(sb) {
      return unwrap(await sb.from('areas').select('area_id,name,zone').order('area_id'));
    },
    async getCategories(sb) {
      return unwrap(await sb.from('property_categories').select('category_id,name,monthly_quota_liters').order('category_id'));
    },
    async getPriceRates(sb) {
      return unwrap(await sb.from('price_rates').select('rate_id,category_id,max_price_per_1000l,effective_from')
        .order('effective_from', { ascending: false }));
    },

    // ---------- household ----------
    async householdOverview(sb, uid) {
      const hh = unwrap(await sb.from('households').select('household_id,address,category_id,area_id,is_active,utility_bill_no')
        .eq('user_id', uid).maybeSingle());
      if (!hh) return null;
      const cat = unwrap(await sb.from('property_categories').select('name,monthly_quota_liters')
        .eq('category_id', hh.category_id).single());
      const month = new Date().toISOString().slice(0, 7) + '-01';          // database runs in UTC
      const usage = unwrap(await sb.from('monthly_usage').select('liters_used')
        .eq('household_id', hh.household_id).eq('month', month).maybeSingle());
      const rate = unwrap(await sb.from('price_rates').select('max_price_per_1000l')
        .eq('category_id', hh.category_id).lte('effective_from', new Date().toISOString())
        .order('effective_from', { ascending: false }).limit(1).maybeSingle());
      return {
        household_id: hh.household_id, address: hh.address, category: cat.name,
        is_active: hh.is_active, utility_bill_no: hh.utility_bill_no,
        quota: cat.monthly_quota_liters, used: usage ? usage.liters_used : 0,
        price_cap: rate ? Number(rate.max_price_per_1000l) : null
      };
    },
    registerHousehold: (sb, areaId, categoryId, address, billNo) =>
      rpc(sb, 'register_household', { p_area_id: areaId, p_category_id: categoryId, p_address: address, p_utility_bill_no: billNo }),
    registerDriver: (sb, licenseNo) =>
      rpc(sb, 'register_driver', { p_license_no: licenseNo }),
    placeOrder: (sb, householdId, liters) => rpc(sb, 'place_order', { p_household: householdId, p_volume: liters }),
    cancelOrder: (sb, orderId) => rpc(sb, 'cancel_order', { p_order: orderId }),
    getOtp: (sb, orderId) => rpc(sb, 'get_my_otp', { p_order: orderId }),
    confirmPayment: (sb, orderId, amountPaid) => rpc(sb, 'confirm_payment', { p_order: orderId, p_amount_paid: amountPaid }),
    rateOrder: (sb, orderId, rating) => rpc(sb, 'rate_order', { p_order: orderId, p_rating: rating }),

    // ---------- driver ----------
    async driverScore(sb) {
      return unwrap(await sb.from('driver_scores').select('driver_id,avg_rating,penalty_points,is_blocked').limit(1).maybeSingle());
    },
    async myPenalties(sb) {
      return unwrap(await sb.from('driver_penalties').select('penalty_id,order_id,reason,points,created_at')
        .order('penalty_id', { ascending: false }).limit(20));
    },
    async householdsByIds(sb, ids) {
      if (!ids.length) return [];
      return unwrap(await sb.from('households').select('household_id,address').in('household_id', ids));
    },
    markDelivered: (sb, orderId, liters) => rpc(sb, 'mark_delivered', { p_order: orderId, p_delivered_liters: liters }),
    reportBreakdown: (sb, orderId) => rpc(sb, 'report_breakdown', { p_order: orderId }),
    verifyOtp: (sb, orderId, otp) => rpc(sb, 'verify_otp', { p_order: orderId, p_otp: otp }),

    // ---------- station operator ----------
    recordFill: (sb, orderId, meter) => rpc(sb, 'record_fill', { p_order: orderId, p_meter_liters: meter }),
    dispatchOrder: (sb, orderId) => rpc(sb, 'dispatch_order', { p_order: orderId }),
    async recentFillings(sb) {
      return unwrap(await sb.from('filling_audit').select('audit_id,order_id,meter_liters,tanker_capacity,recorded_at')
        .order('audit_id', { ascending: false }).limit(15));
    },

    // ---------- regulator ----------
    refreshReports: (sb) => rpc(sb, 'refresh_reports', {}),
    reportDemand: (sb) => rpc(sb, 'report_unfulfilled_demand', {}),
    reportThroughput: (sb) => rpc(sb, 'report_station_throughput', {}),
    reportTurnaround: (sb) => rpc(sb, 'report_driver_turnaround', {}),
    penalizeUnverified: (sb, hours) => rpc(sb, 'penalize_unverified', { p_hours: hours }),
    async driverScores(sb) {
      return unwrap(await sb.from('driver_scores').select('driver_id,driver,avg_rating,penalty_points,is_blocked').order('driver_id'));
    },
        // ---------- regulator admin ----------
    async getStations(sb) {
      return unwrap(await sb.from('stations').select('station_id,name,area_id,operator_id').order('station_id'));
    },
    async getDrivers(sb) {
      return unwrap(await sb.from('drivers').select('driver_id,user_id,license_no,tanker_id,penalty_points,is_blocked').order('driver_id'));
    },
    adminOnboardDriver: (sb, email, license, tankerId) =>
      rpc(sb, 'admin_onboard_driver', { p_email: email, p_license: license, p_tanker_id: tankerId || null }),
    adminAssignTanker: (sb, driverId, tankerId) =>
      rpc(sb, 'admin_assign_tanker', { p_driver_id: driverId, p_tanker_id: tankerId || null }),
    adminAssignOperator: (sb, stationId, email) =>
      rpc(sb, 'admin_assign_operator', { p_station_id: stationId, p_email: email }),
    adminResolveFraud: (sb, flagId) =>
      rpc(sb, 'admin_resolve_fraud', { p_flag_id: flagId }),
    adminUnblockDriver: (sb, driverId) =>
      rpc(sb, 'admin_unblock_driver', { p_driver_id: driverId }),
    adminUnblockTanker: (sb, tankerId) =>
      rpc(sb, 'admin_unblock_tanker', { p_tanker_id: tankerId }),
    async getHouseholds(sb) {
      return unwrap(await sb.from('households')
        .select('household_id,user_id,area_id,category_id,address,utility_bill_no,is_active')
        .order('is_active', { ascending: true }).order('household_id', { ascending: false }));
    },
    async getProfiles(sb) {
      return unwrap(await sb.from('profiles').select('user_id,role,full_name,phone,cnic'));
    },
    adminSetHouseholdStatus: (sb, householdId, isActive, categoryId) =>
      rpc(sb, 'admin_set_household_status', { p_household_id: householdId, p_is_active: isActive, p_category_id: categoryId || null }),
    adminSaveArea: (sb, name, zone, areaId) =>
      rpc(sb, 'admin_save_area', { p_name: name, p_zone: zone || null, p_area_id: areaId || null }),
    adminSaveCategory: (sb, name, quota, categoryId) =>
      rpc(sb, 'admin_save_category', { p_name: name, p_quota: quota, p_category_id: categoryId || null }),
    adminAddPriceRate: (sb, categoryId, maxPrice, effectiveFrom) =>
      rpc(sb, 'admin_add_price_rate', { p_category_id: categoryId, p_max_price: maxPrice, p_effective_from: effectiveFrom || null }),
    adminSaveTanker: (sb, plateNo, capacity, price, tankerId) =>
      rpc(sb, 'admin_save_tanker', { p_plate_no: plateNo, p_capacity: capacity, p_price: price, p_tanker_id: tankerId || null }),
    adminBlockTanker: (sb, tankerId) =>
      rpc(sb, 'admin_block_tanker', { p_tanker_id: tankerId }),
    adminSaveStation: (sb, name, areaId, stationId) =>
      rpc(sb, 'admin_save_station', { p_name: name, p_area_id: areaId, p_station_id: stationId || null }),
    async fraudFlags(sb) {
      return unwrap(await sb.from('fraud_flags').select('flag_id,order_id,flag_type,details,created_at,resolved')
        .order('flag_id', { ascending: false }).limit(30));
    },
    async regBadgeCounts(sb) {
      const [fl, hh] = await Promise.all([
        sb.from('fraud_flags').select('flag_id', { count: 'exact', head: true }).eq('resolved', false),
        sb.from('households').select('household_id', { count: 'exact', head: true }).eq('is_active', false)
      ]);
      if (fl.error) throw new Error(fl.error.message);
      if (hh.error) throw new Error(hh.error.message);
      return { open: fl.count || 0, pendingHh: hh.count || 0 };
    },
    async orderCounts(sb) {
      const statuses = ['WAITING', 'BOOKED', 'FILLED', 'DISPATCHED', 'DELIVERED', 'VERIFIED', 'CANCELLED'];
      const res = await Promise.all(statuses.map((s) =>
        sb.from('orders').select('order_id', { count: 'exact', head: true }).eq('status', s)));
      const out = {};
      statuses.forEach((s, i) => {
        if (res[i].error) throw new Error(res[i].error.message);
        out[s] = res[i].count || 0;
      });
      return out;
    }
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.MwaveApi = api;
})(typeof window !== 'undefined' ? window : globalThis);
