import { importShared } from "./__federation_fn_import-eda1j03z.js";
import { A as App } from "./App-I2j6s7Wm.js";
const React = await importShared("react");
const path = "/npwd_lifestate_app_store";
const Icon = (props) => React.createElement(
  "svg",
  {
    ...props,
    viewBox: "0 0 24 24",
    fill: "currentColor",
    xmlns: "http://www.w3.org/2000/svg"
  },
  React.createElement("path", {
    d: "M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z"
  })
);
const NotificationIcon = (props) => React.createElement(
  "svg",
  {
    ...props,
    viewBox: "0 0 24 24",
    fill: "currentColor",
    xmlns: "http://www.w3.org/2000/svg"
  },
  React.createElement("path", {
    d: "M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z"
  })
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
