import { useCallback, useEffect, useState } from "react";
import {
  type AccountInfo,
  type AccountStatus,
  listAccounts,
  onAccountsChanged,
  probeAccounts,
  removeAccount,
  setActiveServer,
} from "../lib/api";
import { type PageId, NAV, NAV_FOOT, type NavItem } from "./nav";
import { IconMenu, IconPlus, IconSun, IconMoon } from "./icons";

type Props = {
  page: PageId;
  onNav: (p: PageId) => void;
  collapsed: boolean;
  onToggleCollapse: () => void;
  /** 当前会话地址。账号表还没到货时先拿它显示,免得侧栏顶部空一块。 */
  activeServer: string;
  /** 切服/删号后让宿主刷会话(核层已换活跃账号,前端 session 得跟着换)。 */
  onSwitched: () => void;
  theme: "dark" | "light";
  onToggleTheme: () => void;
};

/* 状态点三态(草稿标注 3/25)。
   ★ down 和 unknown 同色(灰)但**不同义**,所以分成两条,不许合并:
     unknown = 还没探过(probeAccounts 没跑或失败) —— 不知道通不通;
     down    = 探过了,确实连不上 —— 知道它坏了。
   合并成一条的话,「探测本身挂了」就会被显示成「服务器挂了」,是两种完全不同的排查方向。 */
const DOT: Record<AccountStatus, { cls: string; tip: string }> = {
  ok: { cls: "on", tip: "连接正常" },
  reauth: { cls: "off", tip: "登录已失效,需重新登录" },
  down: { cls: "none", tip: "探测过,连不上" },
  unknown: { cls: "none", tip: "尚未探测连通性" },
};

const hostOf = (url: string) => url.replace(/^https?:\/\//, "").replace(/\/$/, "");

export default function Sidebar({
  page,
  onNav,
  collapsed,
  onToggleCollapse,
  activeServer,
  onSwitched,
  theme,
  onToggleTheme,
}: Props) {
  const [accounts, setAccounts] = useState<AccountInfo[] | null>(null);
  const [dd, setDd] = useState(false);
  const [ctx, setCtx] = useState<{ x: number; y: number; acc: AccountInfo } | null>(null);
  const [err, setErr] = useState("");

  /* 先 listAccounts 立刻出列表(status 一律 unknown=灰),再 probeAccounts 把真状态补上。
     探测是并发 HTTP,慢;不能让它挡住侧栏渲染。 */
  const load = useCallback(async () => {
    try {
      const list = await listAccounts();
      setAccounts(list);
    } catch (e) {
      setErr(String(e)); // 账号表都拉不到是真故障,不能吞
      return;
    }
    try {
      setAccounts(await probeAccounts());
    } catch {
      // 探测挂了就让状态停在 unknown(灰),不伪造成 down —— 见上面 DOT 的注释。
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load, activeServer]);

  /* ★ 侧栏必须跟着**账号表**变,不能只跟着 activeServer 变。

     旧写法只有上面那个 effect,依赖是 `activeServer` 这个**字符串**。而服务器页里
     改名称/备注/图标/密码/账号根本不动这个字符串(重登同一地址、删掉非活跃账号也不动),
     于是侧栏一直显示旧数据 —— 用户 2026-07-15 报的「首页侧边栏的服务器不能实时响应
     在服务器页的更改」就是这个。Sidebar 还在 Shell 的 key 容器之外,翻页也不会重挂载,
     那份陈旧 state 能活到关程序为止。

     信号由 api.ts 的 invoke 包装层在**任何**改账号表的命令成功后自动广播,不靠调用点自觉。 */
  useEffect(() => onAccountsChanged(() => void load()), [load]);

  // 下拉/右键菜单:点空白/滚动/Esc 关掉(和首页/媒体库一个套路)。
  useEffect(() => {
    const close = () => {
      setDd(false);
      setCtx(null);
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("keydown", onKey);
    };
  }, []);

  useEffect(() => {
    if (!err) return;
    const t = window.setTimeout(() => setErr(""), 3200);
    return () => window.clearTimeout(t);
  }, [err]);

  const active = accounts?.find((a) => a.active) ?? null;
  const activeLabel = active ? active.name || hostOf(active.server) : hostOf(activeServer);
  const activeDot = DOT[active?.status ?? "unknown"];

  /** 切服务器。serverId 就是 account.server(核层按 a.server == server_id 找,见 lib.rs)。 */
  async function pick(a: AccountInfo) {
    setDd(false);
    if (a.active) return;
    try {
      await setActiveServer(a.server);
      onSwitched();
      // 文件浏览型源(夸克/OpenList/飞牛…)没有 Emby 媒体库,首页会是空的 → 直接进文件浏览。
      onNav(a.is_file_browse ? "netdisk" : "home");
    } catch (e) {
      setErr(`切换失败:${e}`);
    }
  }

  async function del(a: AccountInfo) {
    setCtx(null);
    if (!window.confirm(`删除服务器「${a.name || hostOf(a.server)}」?\n本地凭据会一并清除。`)) return;
    try {
      await removeAccount(a.server);
      await load();
      onSwitched(); // 删的可能正是活跃账号,核层会换一个 → 会话必须跟着刷
    } catch (e) {
      setErr(`删除失败:${e}`);
    }
  }

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
      {/* 草稿「侧栏可折叠为窄图标条(顶栏汉堡切换)」—— 汉堡在顶,不在底。 */}
      <div className="sb-top">
        <button
          className="ibtn"
          onClick={onToggleCollapse}
          title={collapsed ? "展开侧栏" : "收起侧栏"}
        >
          <IconMenu size={16} />
        </button>
      </div>

      {/* 标注 1:服务器切换器常驻侧栏顶,点开是锚定下拉浮层(含「添加服务器」)。 */}
      <div className="srv-wrap">
        <button
          className="srv-switch"
          onClick={(e) => {
            e.stopPropagation(); // 否则冒到 window 的 close 上,开了立刻被关
            setDd((v) => !v);
          }}
          title="切换 / 管理服务器"
        >
          <span className="srv-ic">▣</span>
          <span className="srv-meta">
            <span className="srv-name">{activeLabel}</span>
          </span>
          <span className="srv-cv">
            <span className={`dot ${activeDot.cls}`} title={activeDot.tip} />
          </span>
        </button>

        {dd && (
          <div className="dd srv-dd" onClick={(e) => e.stopPropagation()}>
            {accounts == null ? (
              <div className="srv-dd-note">加载账号…</div>
            ) : accounts.length === 0 ? (
              <div className="srv-dd-note">还没有服务器。</div>
            ) : (
              accounts.map((a) => {
                const d = DOT[a.status];
                return (
                  <div
                    key={a.server}
                    className={`li${a.active ? " on" : ""}`}
                    onClick={() => void pick(a)}
                    // 标注 1:右键服务器项 = 编辑/线路/重登/删除。
                    onContextMenu={(e) => {
                      e.preventDefault();
                      setDd(false);
                      setCtx({ x: e.clientX, y: e.clientY, acc: a });
                    }}
                    title={`${a.server}\n${d.tip}\n右键:编辑 / 线路 / 重登 / 删除`}
                  >
                    <span className={`dot ${d.cls}`} />
                    <span className="srv-dd-nm">{a.name || hostOf(a.server)}</span>
                    <span className="rt">{a.user_name}</span>
                  </div>
                );
              })
            )}
            <div className="srv-dd-sep" />
            <div
              className="li"
              onClick={() => {
                setDd(false);
                onNav("addserver");
              }}
            >
              <IconPlus size={13} /> 添加服务器
            </div>
          </div>
        )}
      </div>

      <div className="nav">{NAV.map(item)}</div>
      <div className="nav-spring" />
      <div className="nav-foot">
        {NAV_FOOT.map(item)}
        <button
          className="nav-item"
          onClick={onToggleTheme}
          title={theme === "dark" ? "切到米黄浅色" : "切到沉浸深色"}
        >
          <span className="nav-ic">
            {theme === "dark" ? <IconSun size={17} /> : <IconMoon size={17} />}
          </span>
          <span className="nav-label">{theme === "dark" ? "浅色主题" : "深色主题"}</span>
        </button>
      </div>

      {/* 服务器项右键菜单。编辑/线路/重登的对话框都在服务器页(那是别处的地盘),
          这里只做路由过去,不在侧栏复刻一套 —— 复刻就是两份要同步维护的表单。 */}
      {ctx && (
        <div className="ctxmenu" style={{ left: ctx.x, top: ctx.y }} onClick={(e) => e.stopPropagation()}>
          <div
            className="mi"
            onClick={() => {
              setCtx(null);
              onNav("servers");
            }}
          >
            编辑
          </div>
          <div
            className="mi"
            onClick={() => {
              setCtx(null);
              onNav("servers");
            }}
          >
            线路
          </div>
          <div
            className="mi"
            onClick={() => {
              setCtx(null);
              onNav("servers");
            }}
          >
            重新登录
          </div>
          <div className="mi danger" onClick={() => void del(ctx.acc)}>
            删除
          </div>
        </div>
      )}

      {err && <div className="toast error">{err}</div>}
    </div>
  );
}
