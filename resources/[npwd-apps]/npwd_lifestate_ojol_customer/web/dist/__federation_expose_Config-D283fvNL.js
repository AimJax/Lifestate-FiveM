import { importShared } from "./__federation_fn_import-eda1j03z.js";
import { A as App } from "./App-B3ig4WJ-.js";
const React = await importShared("react");
const path = "/npwd_lifestate_ojol_customer";
const Icon = (props) => React.createElement(
  "svg",
  {
    ...props,
    viewBox: "0 0 24 24",
    fill: "currentColor",
    xmlns: "http://www.w3.org/2000/svg"
  },
  React.createElement("path", { d: "M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5A2.5 2.5 0 1 1 12 6.5a2.5 2.5 0 0 1 0 5z" })
);
const NotificationIcon = (props) => React.createElement(
  "svg",
  {
    ...props,
    viewBox: "0 0 24 24",
    fill: "currentColor",
    xmlns: "http://www.w3.org/2000/svg"
  },
  React.createElement("path", { d: "M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5A2.5 2.5 0 1 1 12 6.5a2.5 2.5 0 0 1 0 5z" })
);
const config = () => ({
  id: "npwd_lifestate_ojol_customer",
  nameLocale: "LAJU",
  color: "#ffffff",
  backgroundColor: "#16201b",
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
});
export {
  config as default,
  path
};
