import { useEffect, useState } from "react";

/** 主题：沉浸深色 / 米黄浅色。持久化到 localStorage，写 <html data-theme>。 */
export type ThemeMode = "dark" | "light";

const KEY = "lp.theme";

function read(): ThemeMode {
  const v = localStorage.getItem(KEY);
  return v === "light" ? "light" : "dark";
}

/** 立即应用(main.tsx 启动时调，避免首帧闪色)。 */
export function applyThemeEarly() {
  document.documentElement.setAttribute("data-theme", read());
}

export function useTheme() {
  const [theme, setTheme] = useState<ThemeMode>(read);

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem(KEY, theme);
  }, [theme]);

  const toggle = () => setTheme((t) => (t === "dark" ? "light" : "dark"));
  return { theme, setTheme, toggle };
}
