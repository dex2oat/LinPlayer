import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { applyThemeEarly } from "./theme/theme";
import { initTelemetry } from "./telemetry";

// 第一行:此后任何一处抛错才有人接得住(含 window.onerror / unhandledrejection)。
initTelemetry();

// 首帧前套用主题，避免闪色。
applyThemeEarly();

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
