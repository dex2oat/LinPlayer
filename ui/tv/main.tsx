import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { initTvFocus, installTvKeyBridge } from "./app/focus";
import "./theme/tv.css";

/* 焦点库和壳键桥都必须在**任何组件挂载之前**装好:
   useFocusable 在挂载时就会向库注册,库没 init 的话注册进的是个空服务,
   表现是"页面画出来了,但遥控器完全没反应"。 */
initTvFocus();
installTvKeyBridge();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
