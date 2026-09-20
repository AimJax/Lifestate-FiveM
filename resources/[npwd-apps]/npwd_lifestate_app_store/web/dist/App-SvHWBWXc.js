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
const React$1 = await importShared("react");
const LAJU_STEM = "3,3 8,3 8,15 3,15";
const LAJU_FOOT = "3,15 13,15 18.5,17.5 13,20 3,20";
const MITRA_BADGE = "17.5,3.5 20,6 17.5,8.5 15,6";
const lajuPolygons = (withBadge) => {
  const shapes = [
    React$1.createElement("polygon", { points: LAJU_STEM, key: 0 }),
    React$1.createElement("polygon", { points: LAJU_FOOT, key: 1 })
  ];
  if (withBadge) shapes.push(React$1.createElement("polygon", { points: MITRA_BADGE, key: 2 }));
  return shapes;
};
const svg = (props, paths) => React$1.createElement("svg", {
  ...props,
  viewBox: "0 0 24 24",
  xmlns: "http://www.w3.org/2000/svg"
}, paths.map((d, index) => React$1.createElement("path", { d, key: index })));
const filled = (...paths) => (props) => svg({ ...props, fill: "currentColor" }, paths);
const stroked = (...paths) => (props) => svg({
  ...props,
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2,
  strokeLinecap: "round",
  strokeLinejoin: "round"
}, paths);
const driver = (props) => React$1.createElement("svg", {
  ...props,
  viewBox: "0 0 24 24",
  fill: "#D71920",
  xmlns: "http://www.w3.org/2000/svg"
}, lajuPolygons(true));
const customer = (props) => React$1.createElement("svg", {
  ...props,
  viewBox: "0 0 24 24",
  fill: "currentColor",
  xmlns: "http://www.w3.org/2000/svg"
}, lajuPolygons(false));
const store = (props) => React$1.createElement("svg", {
  ...props,
  viewBox: "0 0 24 24",
  xmlns: "http://www.w3.org/2000/svg"
}, [
  React$1.createElement("rect", { x: 4, y: 4, width: 7, height: 7, rx: 2, fill: "#FFFFFF", key: 0 }),
  React$1.createElement("rect", { x: 4, y: 13, width: 7, height: 7, rx: 2, fill: "#FFFFFF", key: 1 }),
  React$1.createElement("rect", { x: 13, y: 13, width: 7, height: 7, rx: 2, fill: "#D71920", key: 2 })
]);
const matchmaker = filled("m12 21.35-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z");
const irc = filled("M21 6h-2v9H6v2c0 .55.45 1 1 1h11l4 4V7c0-.55-.45-1-1-1zm-4 6V3c0-.55-.45-1-1-1H3c-.55 0-1 .45-1 1v14l4-4h10c.55 0 1-.45 1-1z");
const social = stroked(
  "M16 7h.01",
  "M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20",
  "m20 7 2 .5-2 .5",
  "M10 18v3",
  "M14 17.75V21",
  "M7 18a6 6 0 0 0 3.84-10.61"
);
const marketplace = filled("M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1.41 16.09V20h-2.67v-1.93c-1.71-.36-3.16-1.46-3.27-3.4h1.96c.1 1.05.82 1.87 2.65 1.87 1.96 0 2.4-.98 2.4-1.59 0-.83-.44-1.61-2.67-2.14-2.48-.6-4.18-1.62-4.18-3.67 0-1.72 1.39-2.84 3.11-3.21V4h2.67v1.95c1.86.45 2.79 1.86 2.85 3.39H14.3c-.05-1.11-.64-1.87-2.22-1.87-1.5 0-2.4.68-2.4 1.64 0 .84.65 1.39 2.67 1.91s4.18 1.39 4.18 3.91c-.01 1.83-1.38 2.83-3.12 3.16z");
const icons = {
  npwd_lifestate_ojol: driver,
  npwd_lifestate_ojol_customer: customer,
  npwd_lifestate_app_store: store,
  MATCH: matchmaker,
  DARKCHAT: irc,
  TWITTER: social,
  MARKETPLACE: marketplace,
  __default: store
};
const accents = {
  npwd_lifestate_ojol: "#FFFFFF",
  npwd_lifestate_ojol_customer: "#D71920",
  npwd_lifestate_app_store: "#1b2440",
  MATCH: "#FE3B73",
  DARKCHAT: "#212121",
  TWITTER: "#0ea5e9",
  MARKETPLACE: "#14b8a6"
};
const DEFAULT_ACCENT = "#1b2440";
const React = await importShared("react");
let cachedStore = null;
const nui = (endpoint, body) => fetch(
  `https://npwd_lifestate_app_store/${endpoint}`,
  body ? {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  } : void 0
).then((response) => response.json());
const REASON_MESSAGES = {
  driver_only: "Hanya Mitra LAJU terdaftar yang bisa memasang aplikasi ini.",
  invalid_character: "Karakter tidak valid.",
  too_fast: "Terlalu cepat. Coba lagi sebentar.",
  database_error: "Gagal menyimpan perubahan. Coba lagi.",
  unknown_app: "Aplikasi tidak dikenal.",
  not_eligible: "Kamu belum memenuhi syarat untuk aplikasi ini.",
  callback_failed: "Gagal menghubungi server."
};
function AppIcon({ id, size }) {
  const Icon = icons[id] || icons.__default;
  return /* @__PURE__ */ jsxRuntimeExports.jsx(Icon, { width: size, height: size });
}
const accentFor = (entry) => accents[entry.id] || DEFAULT_ACCENT;
function statusOf(entry) {
  if (!entry.eligible) return { text: "TIDAK TERSEDIA", color: "#F59E0B" };
  if (entry.installed) return { text: "TERPASANG", color: "#22C55E" };
  return { text: "BELUM TERPASANG", color: "#6F7885" };
}
function AppList({ apps, onOpen }) {
  return /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.list, children: apps.map((entry) => {
    const status = statusOf(entry);
    return /* @__PURE__ */ jsxRuntimeExports.jsxs(
      "button",
      {
        type: "button",
        style: styles.row,
        onClick: () => onOpen(entry.id),
        children: [
          /* @__PURE__ */ jsxRuntimeExports.jsx(
            "div",
            {
              style: {
                ...styles.rowIcon,
                background: accentFor(entry),
                opacity: entry.eligible ? 1 : 0.45
              },
              children: /* @__PURE__ */ jsxRuntimeExports.jsx(AppIcon, { id: entry.id, size: 30 })
            }
          ),
          /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.rowText, children: [
            /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.rowName, children: entry.name }),
            /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.rowDesc, children: entry.description }),
            /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: { ...styles.rowStatus, color: status.color }, children: status.text })
          ] }),
          /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.chevron, children: "›" })
        ]
      },
      entry.id
    );
  }) });
}
function Detail({ entry, busy, onBack, onInstall, onUninstall }) {
  return /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { children: [
    /* @__PURE__ */ jsxRuntimeExports.jsx("button", { type: "button", style: styles.back, onClick: onBack, "aria-label": "Kembali", children: /* @__PURE__ */ jsxRuntimeExports.jsx("svg", { width: "20", height: "20", viewBox: "0 0 24 24", fill: "none", stroke: "#FFFFFF", strokeWidth: "2.5", strokeLinecap: "round", strokeLinejoin: "round", children: /* @__PURE__ */ jsxRuntimeExports.jsx("polyline", { points: "15 18 9 12 15 6" }) }) }),
    /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.detailHeader, children: [
      /* @__PURE__ */ jsxRuntimeExports.jsx(
        "div",
        {
          style: {
            ...styles.detailIcon,
            background: accentFor(entry),
            opacity: entry.eligible ? 1 : 0.45
          },
          children: /* @__PURE__ */ jsxRuntimeExports.jsx(AppIcon, { id: entry.id, size: 38 })
        }
      ),
      /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.detailText, children: [
        /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.detailName, children: entry.name }),
        /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.detailState, children: !entry.eligible ? entry.lockLabel || "Tidak tersedia" : entry.installed ? "Terpasang" : "Belum terpasang" })
      ] })
    ] }),
    /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.detailDescription, children: entry.description }),
    !entry.eligible && /* @__PURE__ */ jsxRuntimeExports.jsx("button", { style: { ...styles.button, ...styles.disabledButton }, disabled: true, children: "TIDAK TERSEDIA" }),
    entry.eligible && entry.installed && /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { children: [
      /* @__PURE__ */ jsxRuntimeExports.jsx(
        "button",
        {
          style: { ...styles.button, ...styles.uninstallButton },
          disabled: busy,
          onClick: () => onUninstall(entry.id),
          children: busy ? "MEMPROSES..." : "UNINSTALL"
        }
      ),
      /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.detailHint, children: "Buka aplikasinya dari layar utama HP." })
    ] }),
    entry.eligible && !entry.installed && /* @__PURE__ */ jsxRuntimeExports.jsx(
      "button",
      {
        style: { ...styles.button, ...styles.installButton },
        disabled: busy,
        onClick: () => onInstall(entry.id),
        children: busy ? "MEMPROSES..." : "INSTALL"
      }
    )
  ] });
}
function App() {
  const [store2, setStore] = React.useState(cachedStore);
  const [loading, setLoading] = React.useState(cachedStore === null);
  const [busyApp, setBusyApp] = React.useState(null);
  const [selected, setSelected] = React.useState(null);
  const [error, setError] = React.useState("");
  const applyStore = (data) => {
    if (!data) return;
    cachedStore = data;
    setStore(data);
  };
  const load = () => {
    setError("");
    return nui("npwd:lifestate_app_store:list").then((response) => {
      if (response.status !== "ok" || !response.data) {
        setError(REASON_MESSAGES.callback_failed);
        return;
      }
      if (response.data.success === false) {
        setError(REASON_MESSAGES[response.data.reason] || REASON_MESSAGES.callback_failed);
        return;
      }
      applyStore(response.data.data);
    }).catch(() => setError(REASON_MESSAGES.callback_failed)).finally(() => setLoading(false));
  };
  React.useEffect(() => {
    load();
  }, []);
  const act = (appId, action) => {
    setBusyApp(appId);
    setError("");
    return nui(`npwd:lifestate_app_store:${action}`, { appId }).then((response) => {
      if (response.status !== "ok" || !response.data) {
        setError(REASON_MESSAGES.callback_failed);
        return;
      }
      if (response.data.success === false) {
        setError(REASON_MESSAGES[response.data.reason] || REASON_MESSAGES.callback_failed);
        return;
      }
      applyStore(response.data.data);
    }).catch(() => setError(REASON_MESSAGES.callback_failed)).finally(() => setBusyApp(null));
  };
  const apps = store2 && Array.isArray(store2.apps) ? store2.apps : null;
  const selectedEntry = apps && selected ? apps.find((entry) => entry.id === selected) || null : null;
  return /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.container, children: /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { style: styles.app, children: [
    !selectedEntry && /* @__PURE__ */ jsxRuntimeExports.jsxs(jsxRuntimeExports.Fragment, { children: [
      /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.brandBar }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.eyebrow, children: "LIFESTATE" }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.title, children: "APP STORE" }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.subtitle, children: "Aplikasi resmi untuk HP kamu" })
    ] }),
    loading && !apps && /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.hint, children: "Memuat..." }),
    !loading && !apps && /* @__PURE__ */ jsxRuntimeExports.jsxs("div", { children: [
      /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.hint, children: "Daftar aplikasi tidak bisa dimuat." }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("button", { style: { ...styles.button, ...styles.installButton }, onClick: load, children: "COBA LAGI" })
    ] }),
    apps && apps.length === 0 && /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.hint, children: "Belum ada aplikasi yang tersedia." }),
    apps && !selectedEntry && /* @__PURE__ */ jsxRuntimeExports.jsx(AppList, { apps, onOpen: setSelected }),
    apps && selectedEntry && /* @__PURE__ */ jsxRuntimeExports.jsx(
      Detail,
      {
        entry: selectedEntry,
        busy: busyApp === selectedEntry.id,
        onBack: () => setSelected(null),
        onInstall: (appId) => act(appId, "install"),
        onUninstall: (appId) => act(appId, "uninstall")
      }
    ),
    error && /* @__PURE__ */ jsxRuntimeExports.jsx("div", { style: styles.error, children: error })
  ] }) });
}
const styles = {
  container: {
    background: "#0B0D12",
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
    boxSizing: "border-box",
    padding: "8px 10px 24px"
  },
  brandBar: {
    width: "28px",
    height: "3px",
    borderRadius: "2px",
    background: "#D71920",
    marginBottom: "12px"
  },
  eyebrow: {
    color: "#6F7885",
    fontSize: "11px",
    fontWeight: "700",
    letterSpacing: "3px",
    marginBottom: "2px"
  },
  title: {
    fontSize: "20px",
    fontWeight: "800",
    letterSpacing: "1px"
  },
  subtitle: {
    color: "#9AA3AF",
    fontSize: "12px",
    marginTop: "4px",
    marginBottom: "22px"
  },
  hint: {
    color: "#9AA3AF",
    fontSize: "13px",
    marginBottom: "14px"
  },
  list: {
    display: "flex",
    flexDirection: "column"
  },
  row: {
    display: "flex",
    alignItems: "center",
    gap: "14px",
    width: "100%",
    boxSizing: "border-box",
    padding: "12px 2px",
    background: "none",
    border: "none",
    borderBottom: "1px solid #1E232D",
    cursor: "pointer",
    color: "#ffffff",
    font: "inherit",
    textAlign: "left"
  },
  rowIcon: {
    width: "54px",
    height: "54px",
    flexShrink: 0,
    borderRadius: "15px",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    color: "#ffffff"
  },
  rowText: {
    flex: 1,
    minWidth: 0
  },
  rowName: {
    fontSize: "14px",
    fontWeight: "700",
    lineHeight: "18px",
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis"
  },
  rowDesc: {
    color: "#9AA3AF",
    fontSize: "11.5px",
    lineHeight: "16px",
    marginTop: "2px",
    display: "-webkit-box",
    WebkitLineClamp: 2,
    WebkitBoxOrient: "vertical",
    overflow: "hidden"
  },
  rowStatus: {
    fontSize: "10px",
    fontWeight: "700",
    letterSpacing: "1px",
    marginTop: "4px"
  },
  chevron: {
    flexShrink: 0,
    color: "#6F7885",
    fontSize: "22px",
    lineHeight: "1",
    paddingLeft: "4px"
  },
  back: {
    display: "inline-flex",
    alignItems: "center",
    background: "none",
    border: "none",
    color: "#FFFFFF",
    padding: "10px 16px 10px 4px",
    margin: "0 0 4px -4px",
    cursor: "pointer",
    font: "inherit"
  },
  detailHeader: {
    display: "flex",
    alignItems: "center",
    gap: "16px",
    marginBottom: "20px"
  },
  detailIcon: {
    width: "76px",
    height: "76px",
    flexShrink: 0,
    borderRadius: "20px",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    color: "#ffffff"
  },
  detailText: {
    flex: 1,
    minWidth: 0
  },
  detailName: {
    fontSize: "19px",
    fontWeight: "800",
    letterSpacing: "0.5px"
  },
  detailState: {
    color: "#9AA3AF",
    fontSize: "11px",
    fontWeight: "700",
    letterSpacing: "1px",
    textTransform: "uppercase",
    marginTop: "4px"
  },
  detailDescription: {
    background: "#181C24",
    border: "1px solid #292F3A",
    borderRadius: "12px",
    padding: "14px",
    color: "#c9d3cc",
    fontSize: "13px",
    lineHeight: "20px",
    marginBottom: "20px"
  },
  detailHint: {
    color: "#6F7885",
    fontSize: "11px",
    marginTop: "8px",
    textAlign: "center"
  },
  button: {
    width: "100%",
    padding: "13px",
    border: "none",
    borderRadius: "11px",
    fontSize: "14px",
    fontWeight: "800",
    letterSpacing: "1px",
    cursor: "pointer"
  },
  installButton: {
    background: "#D71920",
    color: "#FFFFFF"
  },
  uninstallButton: {
    background: "#2A1115",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: "#D71920",
    color: "#ffffff"
  },
  disabledButton: {
    background: "#181C24",
    color: "#6F7885",
    cursor: "not-allowed"
  },
  error: {
    color: "#ef4444",
    fontSize: "13px",
    marginTop: "12px"
  }
};
export {
  App as A,
  jsxRuntimeExports as j
};
