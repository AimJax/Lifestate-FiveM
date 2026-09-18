import { importShared } from "./__federation_fn_import-eda1j03z.js";
import { r as reactExports } from "./index-D0Kxl04a.js";
var jsxRuntime = { exports: {} };
var reactJsxRuntime_production_min = {};
/**
 * @license React
 * react-jsx-runtime.production.min.js
 *
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
var f = reactExports, k = Symbol.for("react.element"), l = Symbol.for("react.fragment"), m = Object.prototype.hasOwnProperty, n = f.__SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED.ReactCurrentOwner, p = { key: true, ref: true, __self: true, __source: true };
function q(c, a, g) {
  var b, d = {}, e = null, h = null;
  void 0 !== g && (e = "" + g);
  void 0 !== a.key && (e = "" + a.key);
  void 0 !== a.ref && (h = a.ref);
  for (b in a) m.call(a, b) && !p.hasOwnProperty(b) && (d[b] = a[b]);
  if (c && c.defaultProps) for (b in a = c.defaultProps, a) void 0 === d[b] && (d[b] = a[b]);
  return { $$typeof: k, type: c, key: e, ref: h, props: d, _owner: n.current };
}
reactJsxRuntime_production_min.Fragment = l;
reactJsxRuntime_production_min.jsx = q;
reactJsxRuntime_production_min.jsxs = q;
{
  jsxRuntime.exports = reactJsxRuntime_production_min;
}
var jsxRuntimeExports = jsxRuntime.exports;
const React = await importShared("react");
let cachedDriverState = null;
let cachedRideState = null;
const REASON_MESSAGES = {
  not_registered: "ANDA BELUM TERDAFTAR SEBAGAI DRIVER OJOL",
  not_eligible: "Order ini tidak tersedia untukmu.",
  order_already_taken: "Order sudah diambil driver lain.",
  ride_not_found: "Order tidak ditemukan.",
  no_offer: "Order ini sudah tidak ditawarkan lagi.",
  no_ride: "Kamu sedang tidak punya order aktif.",
  invalid_ride: "Order tidak valid.",
  busy: "Kamu sedang menerima order.",
  busy_active_ride: "Selesaikan atau batalkan order aktif terlebih dahulu.",
  too_fast: "Terlalu cepat. Coba lagi sebentar.",
  invalid_state: "Gagal mengubah status Ojol.",
  callback_failed: "Gagal mengambil status Ojol.",
  not_ride_owner: "Order ini bukan milikmu.",
  wrong_state: "Aksi tidak tersedia untuk status order ini.",
  too_far_from_pickup: "Kamu terlalu jauh dari titik jemput.",
  too_far_from_destination: "Kamu terlalu jauh dari tujuan.",
  customer_not_on_bike: "Penumpang belum naik motor.",
  customer_not_near: "Penumpang tidak berada di dekatmu.",
  customer_offline: "Penumpang tidak terhubung.",
  offline: "Kamu sedang tidak online.",
  payment_in_progress: "Pembayaran sedang diproses.",
  already_paid_or_processing: "Order ini sudah dibayar.",
  insufficient_funds: "PEMBAYARAN GAGAL - saldo pelanggan tidak mencukupi.",
  payout_failed: "Pembayaran gagal. Coba lagi.",
  company_failed: "Pembayaran gagal (kesalahan perusahaan).",
  customer_wallet_failed: "Pembayaran gagal (dompet pelanggan)."
};
const RANK_LABELS = {
  driver: "Driver",
  senior_driver: "Senior Driver",
  supervisor: "Supervisor",
  ceo: "CEO"
};
const ORDER_STATUS_TEXT = {
  SEARCHING: "Mencari order...",
  ACCEPTED: "Order diterima",
  DRIVER_ENROUTE: "Menuju titik jemput",
  DRIVER_ARRIVED: "Tiba di titik jemput",
  PASSENGER_ONBOARD: "Penumpang di atas motor",
  ENROUTE_DESTINATION: "Menuju tujuan",
  COMPLETED: "Order selesai",
  CANCELLED_CUSTOMER: "Dibatalkan penumpang",
  CANCELLED_DRIVER: "Order dibatalkan",
  FAILED: "Order gagal"
};
const nui = (endpoint, body) => fetch(
  `https://npwd_lifestate_ojol/${endpoint}`,
  body ? {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  } : void 0
).then((response) => response.json());
const formatDistance = (metres) => {
  if (metres === null || metres === void 0) return "--";
  if (metres < 1e3) return `${Math.round(metres)} m`;
  return `${(metres / 1e3).toFixed(1)} km`;
};
function App() {
  const [driverState, setDriverState] = React.useState(cachedDriverState);
  const [rideState, setRideState] = React.useState(cachedRideState);
  const [loading, setLoading] = React.useState(cachedDriverState === null);
  const [submitting, setSubmitting] = React.useState(false);
  const [acting, setActing] = React.useState(null);
  const [error, setError] = React.useState("");
  const applyDriverState = (data) => {
    cachedDriverState = data;
    setDriverState(data);
  };
  const applyRideState = (data) => {
    cachedRideState = data;
    setRideState(data);
  };
  const refreshDriverState = () => nui("npwd:lifestate_ojol:getDriverState").then((response) => {
    if (response.status !== "ok" || !response.data) {
      setError(REASON_MESSAGES.callback_failed);
      return;
    }
    applyDriverState(response.data);
    setError("");
  }).catch(() => setError(REASON_MESSAGES.callback_failed));
  const refreshRideState = () => nui("npwd:lifestate_ojol:getDriverRideState").then((response) => {
    if (response.status !== "ok" || !response.data) return;
    applyRideState(response.data);
  }).catch(() => {
  });
  React.useEffect(() => {
    let active = true;
    Promise.all([refreshDriverState(), refreshRideState()]).finally(() => {
      if (active) setLoading(false);
    });
    return () => {
      active = false;
    };
  }, []);
  React.useEffect(() => {
    const onMessage = (event) => {
      const payload = event.data;
      if (!payload || payload.app !== "npwd_lifestate_ojol") return;
      if (payload.method === "rideState" && payload.data) {
        applyRideState(payload.data);
      } else if (payload.method === "driverState" && payload.data) {
        applyDriverState(payload.data);
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, []);
  const changeDuty = (desiredState) => {
    setSubmitting(true);
    setError("");
    nui("npwd:lifestate_ojol:setDriverDuty", { desiredState }).then((response) => {
      if (response.status !== "ok" || !response.data || !response.data.success) {
        const reason = response.data && response.data.reason;
        setError(REASON_MESSAGES[reason] || REASON_MESSAGES.invalid_state);
        return;
      }
      applyDriverState(response.data);
      setError("");
      refreshRideState();
    }).catch(() => setError(REASON_MESSAGES.invalid_state)).finally(() => setSubmitting(false));
  };
  const answerOffer = (rideId, action) => {
    setActing(rideId);
    setError("");
    nui(`npwd:lifestate_ojol:${action}`, { rideId }).then((response) => {
      if (response.status !== "ok" || !response.data || !response.data.success) {
        const reason = response.data && response.data.reason;
        setError(REASON_MESSAGES[reason] || "Gagal memproses order.");
        refreshRideState();
        return;
      }
      if (response.data.data) applyRideState(response.data.data);
      setError("");
      refreshDriverState();
    }).catch(() => setError("Gagal memproses order.")).finally(() => setActing(null));
  };
  const cancelOrder = () => {
    setActing("cancel");
    setError("");
    nui("npwd:lifestate_ojol:cancelDriverRide").then((response) => {
      if (response.status !== "ok" || !response.data || !response.data.success) {
        const reason = response.data && response.data.reason;
        setError(REASON_MESSAGES[reason] || "Gagal membatalkan order.");
        return;
      }
      if (response.data.data) applyRideState(response.data.data);
      setError("");
      refreshDriverState();
    }).catch(() => setError("Gagal membatalkan order.")).finally(() => setActing(null));
  };
  const tripAction = (action, rideId) => {
    setActing(action);
    setError("");
    nui(`npwd:lifestate_ojol:${action}`, { rideId }).then((response) => {
      if (response.status !== "ok" || !response.data || !response.data.success) {
        const reason = response.data && response.data.reason;
        setError(REASON_MESSAGES[reason] || "Gagal memproses order.");
        refreshRideState();
        return;
      }
      if (response.data.data) applyRideState(response.data.data);
      setError("");
      refreshDriverState();
    }).catch(() => setError("Gagal memproses order.")).finally(() => setActing(null));
  };
  const registered = driverState?.registered;
  const online = driverState?.online;
  const busy = driverState?.busy;
  const rank = driverState?.rank;
  const offers = rideState?.offers || [];
  const activeRide = rideState?.active;
  return /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.container, children: /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.app, children: [
    /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.title, children: "OJOL" }),
    /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.subtitle, children: "Lifestate Ojol Driver" }),
    registered ? /* @__PURE__ */ jsxRuntimeExports.jsxs(jsxRuntimeExports.Fragment, { children: [
      /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.statusRow, children: [
        /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: { ...styles.dot, ...busy ? styles.busyDot : online ? styles.onlineDot : {} } }),
        /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.statusText, children: loading && !driverState ? "--" : busy ? "BUSY" : online ? "ONLINE" : "OFFLINE" })
      ] }),
      /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.metaRow, children: [
        /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.metaItem, children: [
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.metaLabel, children: "Rank" }),
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.metaValue, children: rank ? RANK_LABELS[rank] || rank : "--" })
        ] }),
        /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.metaItem, children: [
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.metaLabel, children: "Rating" }),
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.metaValue, children: driverState?.rating ? Number(driverState.rating).toFixed(1) : "Baru" })
        ] })
      ] }),
      driverState?.profilePhoto ? /* @__PURE__ */ jsxRuntimeExports.jsx("img", { src: driverState.profilePhoto, alt: "Foto profil", style: styles.profilePhoto }) : null,
      activeRide ? /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderCard, children: [
        /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.orderHeader, children: "ORDER AKTIF" }),
        /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.orderStatus, children: ORDER_STATUS_TEXT[activeRide.status] || activeRide.status }),
        /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Penumpang" }),
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderValue, children: activeRide.customerName })
        ] }),
        /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Jarak perjalanan" }),
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderValue, children: formatDistance(activeRide.distanceMeters) })
        ] }),
        /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Tarif pelanggan" }),
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderValue, children: activeRide.fareText })
        ] }),
        /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Pendapatan kamu" }),
          /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: { ...styles.orderValue, ...styles.payout }, children: activeRide.driverPayoutText })
        ] }),
        activeRide.status === "DRIVER_ENROUTE" ? /* @__PURE__ */ jsxRuntimeExports.jsx(
          "button",
          {
            style: { ...styles.button, ...styles.acceptButton, marginTop: "14px" },
            disabled: acting !== null,
            onClick: () => tripAction("driverArrived", activeRide.rideId),
            children: "SAYA SUDAH SAMPAI"
          }
        ) : null,
        activeRide.status === "DRIVER_ARRIVED" ? /* @__PURE__ */ jsxRuntimeExports.jsx(
          "button",
          {
            style: { ...styles.button, ...styles.acceptButton, marginTop: "14px" },
            disabled: acting !== null,
            onClick: () => tripAction("passengerBoarded", activeRide.rideId),
            children: "PENUMPANG SUDAH NAIK"
          }
        ) : null,
        activeRide.status === "ENROUTE_DESTINATION" ? /* @__PURE__ */ jsxRuntimeExports.jsx(
          "button",
          {
            style: { ...styles.button, ...styles.acceptButton, marginTop: "14px" },
            disabled: acting !== null,
            onClick: () => tripAction("completeRide", activeRide.rideId),
            children: "SELESAIKAN PERJALANAN"
          }
        ) : null,
        activeRide.paymentFailed ? /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.paymentFailed, children: [
          "PEMBAYARAN GAGAL - saldo pelanggan tidak mencukupi.",
          /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.hint, children: "Tunggu pelanggan top up atau ganti metode pembayaran." })
        ] }) : null,
        /* @__PURE__ */ jsxRuntimeExports.jsx(
          "button",
          {
            style: { ...styles.button, ...styles.dangerButton, marginTop: "14px" },
            disabled: acting !== null,
            onClick: cancelOrder,
            children: "BATALKAN ORDER"
          }
        ),
        /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.hint, children: "Selesaikan atau batalkan order aktif terlebih dahulu." })
      ] }) : null,
      !activeRide && offers.length > 0 ? /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderCard, children: [
        /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.orderHeader, children: "ORDER BARU" }),
        offers.map((offer) => /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.offerBlock, children: [
          /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Customer" }),
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderValue, children: offer.customerName })
          ] }),
          /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Jarak ke penumpang" }),
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderValue, children: formatDistance(offer.distanceToPickupMeters) })
          ] }),
          /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Jarak perjalanan" }),
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderValue, children: formatDistance(offer.rideDistanceMeters) })
          ] }),
          /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Tarif pelanggan" }),
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderValue, children: offer.fareText })
          ] }),
          /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.orderLine, children: [
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: styles.orderLabel, children: "Pendapatan driver" }),
            /* @__PURE__ */ jsxRuntimeExports.jsx("span", { style: { ...styles.orderValue, ...styles.payout }, children: offer.driverPayoutText })
          ] }),
          /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.offerButtons, children: [
            /* @__PURE__ */ jsxRuntimeExports.jsx(
              "button",
              {
                style: { ...styles.button, ...styles.acceptButton },
                disabled: acting !== null,
                onClick: () => answerOffer(offer.rideId, "acceptRideOffer"),
                children: "TERIMA"
              }
            ),
            /* @__PURE__ */ jsxRuntimeExports.jsx(
              "button",
              {
                style: { ...styles.button, ...styles.declineButton },
                disabled: acting !== null,
                onClick: () => answerOffer(offer.rideId, "rejectRideOffer"),
                children: "TOLAK"
              }
            )
          ] })
        ] }, offer.rideId))
      ] }) : null,
      !busy && /* @__PURE__ */ jsxRuntimeExports.jsx(
        "button",
        {
          style: { ...styles.button, ...online ? styles.offlineButton : styles.onlineButton },
          disabled: submitting,
          onClick: () => changeDuty(!online),
          children: online ? "SELESAI NGE-OJOL" : "MULAI NGE-OJOL"
        }
      )
    ] }) : /* @__PURE__ */ jsxRuntimeExports.jsxs(jsxRuntimeExports.Fragment, { children: [
      /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.desc, children: REASON_MESSAGES.not_registered }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.hint, children: "Hubungi CEO Ojol untuk mendaftar sebagai driver." })
    ] }),
    /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.error, children: error })
  ] }) });
}
const styles = {
  container: {
    background: "#111111",
    color: "#ffffff",
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
    width: "100%",
    flex: 1,
    maxHeight: "100%",
    overflow: "auto",
    boxSizing: "border-box",
    display: "flex",
    alignItems: "flex-start",
    justifyContent: "center",
    padding: "16px"
  },
  app: {
    width: "100%",
    maxWidth: "380px",
    background: "#1a1a1a",
    borderRadius: "16px",
    padding: "24px",
    textAlign: "center",
    boxSizing: "border-box",
    boxShadow: "0 8px 32px rgba(0,0,0,0.4)"
  },
  title: {
    fontSize: "22px",
    fontWeight: "700",
    letterSpacing: "1px",
    marginBottom: "4px"
  },
  subtitle: {
    color: "#888888",
    fontSize: "12px",
    textTransform: "uppercase",
    letterSpacing: "2px",
    marginBottom: "20px"
  },
  statusRow: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: "8px",
    marginBottom: "12px"
  },
  dot: {
    width: "12px",
    height: "12px",
    borderRadius: "50%",
    background: "#ef4444",
    boxShadow: "0 0 8px #ef4444"
  },
  onlineDot: {
    background: "#22c55e",
    boxShadow: "0 0 8px #22c55e"
  },
  busyDot: {
    background: "#f59e0b",
    boxShadow: "0 0 8px #f59e0b"
  },
  statusText: {
    fontSize: "16px",
    fontWeight: "600"
  },
  desc: {
    color: "#888888",
    fontSize: "13px",
    marginBottom: "24px",
    lineHeight: "1.4"
  },
  hint: {
    color: "#666666",
    fontSize: "12px",
    marginTop: "10px",
    lineHeight: "1.4"
  },
  metaRow: {
    display: "flex",
    justifyContent: "center",
    gap: "24px",
    marginBottom: "20px"
  },
  metaItem: {
    display: "flex",
    flexDirection: "column",
    gap: "2px"
  },
  metaLabel: {
    color: "#888888",
    fontSize: "11px",
    textTransform: "uppercase",
    letterSpacing: "1px"
  },
  metaValue: {
    color: "#ffffff",
    fontSize: "14px",
    fontWeight: "600"
  },
  profilePhoto: {
    width: "72px",
    height: "72px",
    borderRadius: "50%",
    objectFit: "cover",
    margin: "0 auto 20px",
    display: "block",
    border: "2px solid #2f2f2f"
  },
  orderCard: {
    background: "#141414",
    border: "1px solid #2f2f2f",
    borderRadius: "12px",
    padding: "16px",
    marginBottom: "18px",
    textAlign: "left"
  },
  orderHeader: {
    color: "#f59e0b",
    fontSize: "12px",
    fontWeight: "700",
    letterSpacing: "2px",
    marginBottom: "10px",
    textAlign: "center"
  },
  orderStatus: {
    color: "#ffffff",
    fontSize: "14px",
    fontWeight: "600",
    textAlign: "center",
    marginBottom: "12px"
  },
  offerBlock: {
    borderTop: "1px solid #2f2f2f",
    paddingTop: "10px",
    marginTop: "10px"
  },
  orderLine: {
    display: "flex",
    justifyContent: "space-between",
    gap: "12px",
    marginBottom: "6px"
  },
  orderLabel: {
    color: "#888888",
    fontSize: "12px"
  },
  orderValue: {
    color: "#ffffff",
    fontSize: "13px",
    fontWeight: "600",
    textAlign: "right"
  },
  payout: {
    color: "#22c55e"
  },
  paymentFailed: {
    background: "#2a1414",
    border: "1px solid #ef4444",
    borderRadius: "10px",
    color: "#ef4444",
    fontSize: "13px",
    fontWeight: "600",
    marginTop: "14px",
    padding: "12px"
  },
  offerButtons: {
    display: "flex",
    gap: "10px",
    marginTop: "14px"
  },
  button: {
    width: "100%",
    padding: "14px",
    border: "none",
    borderRadius: "10px",
    fontSize: "15px",
    fontWeight: "700",
    letterSpacing: "0.5px",
    cursor: "pointer",
    transition: "opacity 0.2s"
  },
  acceptButton: {
    background: "#22c55e",
    color: "#000000"
  },
  declineButton: {
    background: "#2f2f2f",
    color: "#ffffff"
  },
  dangerButton: {
    background: "#ef4444",
    color: "#ffffff"
  },
  onlineButton: {
    background: "#22c55e",
    color: "#000000"
  },
  offlineButton: {
    background: "#ef4444",
    color: "#ffffff"
  },
  error: {
    color: "#ef4444",
    fontSize: "13px",
    marginTop: "16px"
  }
};
export {
  App as A,
  jsxRuntimeExports as j
};
