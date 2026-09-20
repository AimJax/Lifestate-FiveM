import { importShared } from "./__federation_fn_import-eda1j03z.js";
import { A as App, j as jsxRuntimeExports } from "./App-CdoAK7KA.js";
await importShared("react");
const path = "/npwd_lifestate_ojol_customer";
const LAJU_STEM = "3,3 8,3 8,15 3,15";
const LAJU_FOOT = "3,15 13,15 18.5,17.5 13,20 3,20";
const Icon = (props) => /* @__PURE__ */ jsxRuntimeExports.jsxs(
  "svg",
  {
    ...props,
    viewBox: "0 0 24 24",
    fill: "currentColor",
    xmlns: "http://www.w3.org/2000/svg",
    children: [
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: LAJU_STEM }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: LAJU_FOOT })
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
      /* @__PURE__ */ jsxRuntimeExports.jsx("polygon", { points: LAJU_FOOT })
    ]
  }
);
const config = () => ({
  id: "npwd_lifestate_ojol_customer",
  nameLocale: "LAJU",
  color: "#FFFFFF",
  backgroundColor: "#D71920",
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
});
export {
  config as default,
  path
};
