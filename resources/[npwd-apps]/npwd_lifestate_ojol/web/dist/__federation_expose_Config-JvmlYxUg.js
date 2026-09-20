import { importShared } from "./__federation_fn_import-eda1j03z.js";
import { A as App, j as jsxRuntimeExports } from "./App-B2jK52Pq.js";
await importShared("react");
const path = "/npwd_lifestate_ojol";
const LAJU_STEM = "3,3 8,3 8,15 3,15";
const LAJU_FOOT = "3,15 13,15 18.5,17.5 13,20 3,20";
const MITRA_BADGE = "17.5,3.5 20,6 17.5,8.5 15,6";
const Icon = (props) => /* @__PURE__ */ jsxRuntimeExports.jsxs(
  "svg",
  {
    ...props,
    viewBox: "0 0 24 24",
    fill: "currentColor",
    xmlns: "http://www.w3.org/2000/svg",
    children: [
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: LAJU_STEM }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: LAJU_FOOT }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: MITRA_BADGE })
    ]
  }
);
const NotificationIcon = (props) => /* @__PURE__ */ jsxRuntimeExports.jsxs(
  "svg",
  {
    ...props,
    viewBox: "0 0 24 24",
    fill: "currentColor",
    xmlns: "http://www.w3.org/2000/svg",
    children: [
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: LAJU_STEM }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: LAJU_FOOT }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: MITRA_BADGE })
    ]
  }
);
const config = () => ({
  id: "npwd_lifestate_ojol",
  nameLocale: "LAJU Mitra",
  color: "#D71920",
  backgroundColor: "#FFFFFF",
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
});
export {
  config as default,
  path
};
