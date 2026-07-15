import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { applyThemeEarly } from "./theme/theme";

// 首帧前套用主题，避免闪色。
applyThemeEarly();

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
