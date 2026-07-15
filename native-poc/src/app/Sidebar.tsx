import { type PageId, NAV, NAV_FOOT, type NavItem } from "./nav";
import { IconChevronLeft, IconSun, IconMoon } from "./icons";

type Props = {
  page: PageId;
  onNav: (p: PageId) => void;
  collapsed: boolean;
  onToggleCollapse: () => void;
  serverName: string | null;
  connected: boolean;
  onServerClick: () => void;
  theme: "dark" | "light";
  onToggleTheme: () => void;
};

export default function Sidebar({
  page,
  onNav,
  collapsed,
  onToggleCollapse,
  serverName,
  connected,
  onServerClick,
  theme,
  onToggleTheme,
}: Props) {
  const item = (n: NavItem) => {
    const Icon = n.icon;
    return (
      <button
        key={n.id}
        className={`nav-item${page === n.id ? " on" : ""}`}
        onClick={() => onNav(n.id)}
        title={n.label}
      >
        <span className="nav-ic">
          <Icon size={17} />
        </span>
        <span className="nav-label">{n.label}</span>
      </button>
    );
  };

  return (
    <div className={`sidebar${collapsed ? " collapsed" : ""}`}>
      <button className="srv-switch" onClick={onServerClick} title="切换 / 管理服务器">
        <span className="srv-ic">▣</span>
        <span className="srv-meta">
          <span className="srv-name">{serverName ?? "未连接"}</span>
        </span>
        <span className="srv-cv">
          <span className={`dot ${connected ? "on" : "none"}`} />
        </span>
      </button>

      <div className="nav">{NAV.map(item)}</div>
      <div className="nav-spring" />
      <div className="nav-foot">
        {NAV_FOOT.map(item)}
        <div className="nav" style={{ flexDirection: "row", gap: 4, marginTop: 4 }}>
          <button
            className="nav-item"
            onClick={onToggleCollapse}
            title={collapsed ? "展开侧栏" : "收起侧栏"}
            style={{ justifyContent: "center" }}
          >
            <span className="nav-ic">
              <IconChevronLeft size={16} className={collapsed ? "flip" : undefined} />
            </span>
          </button>
          {!collapsed && (
            <button
              className="nav-item"
              onClick={onToggleTheme}
              title={theme === "dark" ? "切到米黄浅色" : "切到沉浸深色"}
              style={{ justifyContent: "center" }}
            >
              <span className="nav-ic">
                {theme === "dark" ? <IconSun size={16} /> : <IconMoon size={16} />}
              </span>
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
