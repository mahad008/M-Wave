// M-WAVE front end: data layer. Every database call lives here (no HTML in this file).
// Works in the browser (window.MwaveApi) and in Node for testing (module.exports).
(function (root) {
  'use strict';

  // orders has no "select *": the otp_hash column is blocked by the database on purpose.
  const ORDER_COLS = 'order_id,household_id,tanker_id,driver_id,station_id,volume_liters,price,status,' +
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
      return unwrap(await sb.from('profiles').select('user_id,role,full_name,phone').eq('user_id', uid).maybeSingle());
    },
    async listOrders(sb, limit = 50) {
      return unwrap(await sb.from('orders').select(ORDER_COLS).order('order_id', { ascending: false }).limit(limit));
    },
    async orderHistory(sb, orderId) {
      return unwrap(await sb.from('order_status_history').select('old_status,new_status,changed_at')
        .eq('order_id', orderId).order('history_id', { ascending: true }));
    },
    async getTankers(sb) {
      return unwrap(await sb.from('tankers').select('tanker_id,plate_no,capacity_liters,price_per_1000l'));
    },

    // ---------- household ----------
    async householdOverview(sb, uid) {
      const hh = unwrap(await sb.from('households').select('household_id,address,category_id,area_id')
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
        quota: cat.monthly_quota_liters, used: usage ? usage.liters_used : 0,
        price_cap: rate ? Number(rate.max_price_per_1000l) : null
      };
    },
    placeOrder: (sb, householdId, liters) => rpc(sb, 'place_order', { p_household: householdId, p_volume: liters }),
    cancelOrder: (sb, orderId) => rpc(sb, 'cancel_order', { p_order: orderId }),
    getOtp: (sb, orderId) => rpc(sb, 'get_my_otp', { p_order: orderId }),
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
    async fraudFlags(sb) {
      return unwrap(await sb.from('fraud_flags').select('flag_id,order_id,flag_type,details,created_at,resolved')
        .order('flag_id', { ascending: false }).limit(30));
    },
    async orderCounts(sb) {
      const out = {};
      for (const s of ['WAITING', 'BOOKED', 'FILLED', 'DISPATCHED', 'DELIVERED', 'VERIFIED', 'CANCELLED']) {
        const r = await sb.from('orders').select('order_id', { count: 'exact', head: true }).eq('status', s);
        if (r.error) throw new Error(r.error.message);
        out[s] = r.count || 0;
      }
      return out;
    }
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.MwaveApi = api;
})(typeof window !== 'undefined' ? window : globalThis);
