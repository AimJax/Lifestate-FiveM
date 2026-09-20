import { importShared } from "./__federation_fn_import-eda1j03z.js";
import { A as App, j as jsxRuntimeExports } from "./App-CFJpm4B0.js";
const React = await importShared("react");
const path = "/npwd_lifestate_app_store";
const STORE_CELL_A = { x: 4, y: 4 };
const STORE_CELL_B = { x: 4, y: 13 };
const STORE_CELL_C = { x: 13, y: 13 };
const CELL_SIZE = 7;
const CELL_RX = 2;
const LajuStoreMark = () => /* @__PURE__ */ jsxRuntimeExports.jsxs(React.Fragment, { children: [
  /* @__PURE__ */ jsxRuntimeExports.jsx("rect", { x: STORE_CELL_A.x, y: STORE_CELL_A.y, width: CELL_SIZE, height: CELL_SIZE, rx: CELL_RX, fill: "#FFFFFF" }),
  /* @__PURE__ */ jsxRuntimeExports.jsx("rect", { x: STORE_CELL_B.x, y: STORE_CELL_B.y, width: CELL_SIZE, height: CELL_SIZE, rx: CELL_RX, fill: "#FFFFFF" }),
  /* @__PURE__ */ jsxRuntimeExports.jsx("rect", { x: STORE_CELL_C.x, y: STORE_CELL_C.y, width: CELL_SIZE, height: CELL_SIZE, rx: CELL_RX, fill: "#D71920" })
] });
const HOME_VIEWBOX = "-4 -4 32 32";
const Icon = (props) => /* @__PURE__ */ jsxRuntimeExports.jsx(
  "svg",
  {
    ...props,
    viewBox: HOME_VIEWBOX,
    xmlns: "http://www.w3.org/2000/svg",
    children: /* @__PURE__ */ jsxRuntimeExports.jsx(LajuStoreMark, {})
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
      /* @__PURE__ */ jsxRuntimeExports.jsx("rect", { x: STORE_CELL_A.x, y: STORE_CELL_A.y, width: CELL_SIZE, height: CELL_SIZE, rx: CELL_RX }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("rect", { x: STORE_CELL_B.x, y: STORE_CELL_B.y, width: CELL_SIZE, height: CELL_SIZE, rx: CELL_RX }),
      /* @__PURE__ */ jsxRuntimeExports.jsx("rect", { x: STORE_CELL_C.x, y: STORE_CELL_C.y, width: CELL_SIZE, height: CELL_SIZE, rx: CELL_RX })
    ]
  }
);
const config = () => ({
  id: "npwd_lifestate_app_store",
  nameLocale: "Lifestate App Store",
  color: "#ffffff",
  backgroundColor: "#1b2440",
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
});
export {
  config as default,
  path
};
