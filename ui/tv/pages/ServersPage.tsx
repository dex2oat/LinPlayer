import { useCallback, useEffect, useState } from "react";
import {
  accountIcon,
  listAccounts,
  onAccountsChanged,
  probeAccounts,
  removeAccount,
  reorderAccounts,
  setActiveServer,
  type AccountInfo,
  type AccountStatus,
} from "@shared/api";
import type { Route } from "../App";
import { onTvKey } from "../app/focus";
import { Icon } from "../app/icons";
import { FocusBoundary, FocusColumn, FocusItem } from "../components/Focus";

/** 服务器页(草稿 11)+ 排序模式(草稿 22)。

    ★ 卡片**只显示 图标 / 名称 / 备注**三样。名字下面那行小字是**备注**,不是域名、不是线路。
      URL 只在线路管理页和添加服务器页出现,这里一律不提。
      媒体库数量也不外显 —— 它对「我现在要用哪一台」这个决定毫无帮助,只是把卡片塞满。
    ★ **排序不是另一个页面,是这一页的第二个模式**:卡片、栅格、间距全部照搬同一套常量
      (下面的 CARD / GRID),变的只有顶部提示带和虚线框。
      画成两套版式,用户会以为自己进错页了。
    ★ 状态点必须是**真探测**(probeAccounts)。PC 端曾经传死值 true,绿灯永远亮着 = 等于没有。 */

/** 3 列。方向键上下 = ±COLS,排序模式要靠它算落点,所以必须和栅格是同一个数。 */
const COLS = 3;

const GRID: React.CSSProperties = {
  display: "grid",
  gridTemplateColumns: `repeat(${COLS}, 1fr)`,
  gap: 32,
};

/** 卡片外壳。排序模式只在这份基础上叠 border,别另写一份。 */
const CARD: React.CSSProperties = {
  padding: 30,
  borderRadius: 18,
  background: "#161a20",
  display: "flex",
  flexDirection: "column",
  alignItems: "center",
  textAlign: "center",
  minHeight: 250,
};

/** 三态 → 颜色。unknown(还没探过)必须与 down(探过确实不通)不同色,
 *  否则「没探测」会被读成「挂了」。 */
function dotColor(s: AccountStatus): string {
  if (s === "ok") return "var(--good)";
  if (s === "unknown") return "var(--tv-ink-3)";
  return "var(--danger)"; // down / reauth 都是「现在用不了」
}

export default function ServersPage({ go }: { go: (r: Route) => void }) {
  const [accs, setAccs] = useState<AccountInfo[]>([]);
  /* 探测结果单独存一份 Map,不合进 accs ——
     切服/删服会让 accs 整表重取,合在一起的话每次重取都把绿灯打回灰,像是掉线了。 */
  const [probed, setProbed] = useState<Record<string, AccountStatus>>({});
  const [menu, setMenu] = useState<AccountInfo | null>(null);
  const [confirmDel, setConfirmDel] = useState(false);
  const [icons, setIcons] = useState<Record<string, string>>({});
  const [toast, setToast] = useState<string | null>(null);
  /* 排序模式:from = 进入时的位置,at = 当前落点。**返回键取消 = 直接丢掉 at**,
     所以列表在提交前一次都不动核层。 */
  const [drag, setDrag] = useState<{ from: number; at: number } | null>(null);
  /* 该抢焦点的卡。排序模式里卡片不是 FocusItem(方向键要移动卡片,不是移动焦点),
     退出模式时全部重新挂载 → 不指定的话焦点掉到 body,遥控器整个失灵。 */
  const [focusIdx, setFocusIdx] = useState(0);

  const load = useCallback(() => {
    listAccounts().then(setAccs).catch(() => setAccs([]));
  }, []);

  /* 账号表的任何变更(切换/删除/排序)都由 api 层广播,这里只管重取 ——
     别在每个调用点后面手工 load(),漏一个就是「删了还在列表里」。 */
  useEffect(() => {
    load();
    return onAccountsChanged(load);
  }, [load]);

  /* 探测只在进页时跑一次。它是并发网络请求,跟着账号表每次变更重跑
     = 切一次服务器就全表再探一遍,白等。 */
  useEffect(() => {
    probeAccounts()
      .then((list) =>
        setProbed(Object.fromEntries(list.map((a) => [a.server, a.status]))),
      )
      .catch(() => {});
  }, []);

  /* 图标逐个取(核层带缓存)。失败的不记,渲染时回落内置渐变块 —— 不画「加载失败」。 */
  useEffect(() => {
    for (const a of accs) {
      if (icons[a.server] !== undefined) continue;
      accountIcon(a.server)
        .then((uri) => setIcons((m) => ({ ...m, [a.server]: uri })))
        .catch(() => {});
    }
  }, [accs, icons]);

  const say = useCallback((m: string) => {
    setToast(m);
    setTimeout(() => setToast(null), 3000);
  }, []);

  /* 排序模式的方向键。★ 用 capture + stopPropagation 截住 —— 否则焦点库也会收到同一个
     按键去挪焦点,而此刻「方向键」的语义是挪**卡片**。 */
  useEffect(() => {
    if (!drag) return;
    const n = accs.length;
    const h = (e: KeyboardEvent) => {
      let to = drag.at;
      switch (e.key) {
        case "ArrowLeft":
          to -= 1;
          break;
        case "ArrowRight":
          to += 1;
          break;
        case "ArrowUp":
          to -= COLS;
          break;
        case "ArrowDown":
          to += COLS;
          break;
        case "Enter":
          e.preventDefault();
          e.stopPropagation();
          setDrag(null);
          setFocusIdx(drag.at);
          if (drag.at !== drag.from) {
            reorderAccounts(drag.from, drag.at)
              .then(() => say("顺序已保存"))
              .catch((err) => say(String(err)));
          }
          return;
        default:
          return;
      }
      e.preventDefault();
      e.stopPropagation();
      if (to >= 0 && to < n) setDrag({ from: drag.from, at: to });
    };
    window.addEventListener("keydown", h, true);
    return () => window.removeEventListener("keydown", h, true);
  }, [drag, accs.length, say]);

  /* 返回键:先收面板,再退排序模式(**还原到进入前的顺序**,不是确认当前顺序)。
     两者都没开时不拦 —— 让 App 的返回逻辑照常走。 */
  useEffect(
    () =>
      onTvKey((k) => {
        if (k !== "back") return;
        if (menu) {
          setMenu(null);
          setConfirmDel(false);
        } else if (drag) {
          setFocusIdx(drag.from);
          setDrag(null);
        }
      }),
    [menu, drag],
  );

  /* 排序模式下显示的是「假想中的新顺序」:核层没动,只是把那张卡搬到 at 的位置预览。 */
  const shown = drag ? move(accs, drag.from, drag.at) : accs;

  return (
    <>
      <FocusColumn focusKey="SERVERS">
        {drag ? (
          <div
            style={{
              background: "var(--accent-soft)",
              borderRadius: 14,
              padding: "18px 26px",
              marginBottom: 30,
              display: "flex",
              alignItems: "center",
              gap: 16,
              boxShadow: "inset 0 0 0 2px var(--accent)",
            }}
          >
            <Icon n="up" className="ic ic-btn" />
            <div style={{ fontSize: 20 }}>
              排序模式 · 方向键移动位置,确认键放下,返回键取消
            </div>
          </div>
        ) : (
          <>
            <div className="ptitle">服务器</div>
            <div className="psub">确认键打开操作(切换 / 线路管理 / 排序 / 删除)</div>
          </>
        )}

        <div style={GRID}>
          {shown.map((a, i) => {
            const moving = drag != null && i === drag.at;
            return (
              <ServerCard
                key={a.server}
                acc={a}
                icon={icons[a.server]}
                status={probed[a.server] ?? a.status}
                /* 排序模式下卡片不可聚焦:此刻方向键归卡片用。 */
                reorder={drag != null}
                moving={moving}
                pos={moving ? `正在移动 · 位置 ${drag.at + 1} / ${accs.length}` : null}
                autoFocus={drag == null && i === focusIdx}
                onEnter={() => setMenu(a)}
              />
            );
          })}

          {/* 添加入口。排序模式下不画 —— 它不参与排序,留着只会让「位置 n/N」数不对。 */}
          {!drag && (
            <FocusItem
              className="fx"
              style={{
                ...CARD,
                background: "transparent",
                border: "2px dashed #2f3640",
                justifyContent: "center",
                gap: 16,
                fontSize: 22,
                color: "var(--tv-ink-2)",
              }}
              onEnter={() => go({ page: "addserver" })}
            >
              <Icon n="plus" className="ic ic-lg" />
              添加服务器
            </FocusItem>
          )}
        </div>
      </FocusColumn>

      {menu && (
        <ActionPanel
          acc={menu}
          confirmDel={confirmDel}
          onAskDel={() => setConfirmDel(true)}
          onClose={() => {
            setMenu(null);
            setConfirmDel(false);
          }}
          onSwitch={() => {
            setActiveServer(menu.server)
              .then(() => say(`已切换到 ${menu.name}`))
              .catch((e) => say(String(e)));
            setMenu(null);
          }}
          onLines={() => {
            setMenu(null);
            /* 字段名必须是 serverId —— App 的 lines 分支读的是 route.serverId,
               传 itemId 的话 LinesPage 拿到 undefined,线路管理进去是空的。 */
            go({ page: "lines", serverId: menu.server, title: menu.name });
          }}
          onReorder={() => {
            const from = accs.findIndex((x) => x.server === menu.server);
            setMenu(null);
            if (from >= 0) setDrag({ from, at: from });
          }}
          onDelete={() => {
            removeAccount(menu.server)
              .then(() => say("已删除"))
              .catch((e) => say(String(e)));
            setMenu(null);
            setConfirmDel(false);
            setFocusIdx(0);
          }}
        />
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/* ------------------------------------------------------------
   卡片。常态和排序态是**同一个组件**,差别只有 border 和多出的一行位置提示。
   ------------------------------------------------------------ */

function ServerCard({
  acc,
  icon,
  status,
  reorder,
  moving,
  pos,
  autoFocus,
  onEnter,
}: {
  acc: AccountInfo;
  icon: string | undefined;
  status: AccountStatus;
  reorder: boolean;
  moving: boolean;
  pos: string | null;
  autoFocus: boolean;
  onEnter: () => void;
}) {
  const inner = (
    <>
      <div
        style={{
          width: 96,
          height: 96,
          borderRadius: 22,
          marginBottom: 20,
          overflow: "hidden",
          flex: "none",
          /* 没图标时用品牌渐变块,不画问号:一屏几张卡,每张都写「无图标」更吵。 */
          background: icon
            ? "#2a3038"
            : "linear-gradient(140deg, var(--accent), #3f73d6)",
        }}
      >
        {icon && (
          <img
            src={icon}
            alt=""
            style={{ width: "100%", height: "100%", objectFit: "cover" }}
          />
        )}
      </div>
      <div
        style={{
          fontSize: 26,
          fontWeight: 640,
          display: "flex",
          alignItems: "center",
          gap: 12,
        }}
      >
        {acc.name}
        <span
          style={{
            width: 12,
            height: 12,
            borderRadius: "50%",
            background: dotColor(status),
            flex: "none",
          }}
        />
      </div>
      {/* ★ 这一行是**备注**。不是域名、不是线路。 */}
      {acc.remark && (
        <div style={{ fontSize: 18, color: "var(--tv-ink-3)", marginTop: 10 }}>
          {acc.remark}
        </div>
      )}
      {/* 位置写在卡里 —— 光看排布,三米外数不清这是第几个。 */}
      {pos && (
        <div style={{ fontSize: 17, color: "var(--accent)", marginTop: 8 }}>{pos}</div>
      )}
    </>
  );

  if (reorder) {
    return (
      <div
        className={moving ? "" : "dim"}
        style={{
          ...CARD,
          border: `3px dashed ${moving ? "var(--accent)" : "#2f3640"}`,
        }}
      >
        {inner}
      </div>
    );
  }

  return (
    <FocusItem
      className={`fx${acc.active ? "" : " dim"}`}
      style={CARD}
      autoFocus={autoFocus}
      onEnter={onEnter}
    >
      {inner}
    </FocusItem>
  );
}

/* ------------------------------------------------------------
   操作面板(草稿 20 的「服务器页 · 操作」)
   ------------------------------------------------------------ */

/** ★ 面板由**确认键**打开,不是菜单键。草稿写的是菜单键 + 长按确认进排序,
 *  但这两条在真机上都不保证拿得到:菜单键要 Activity 转发(壳还没建),
 *  长按要 onEnterRelease(Focus.tsx 没暴露,而那份文件不归这里改)。
 *  于是把「切换 / 线路管理 / 排序 / 删除」全收进这一个面板 —— 一个确认键就够,
 *  没有任何能力躲在拿不到的按键后面。壳建好后再把菜单键接成同一个入口即可。 */
function ActionPanel({
  acc,
  confirmDel,
  onAskDel,
  onClose,
  onSwitch,
  onLines,
  onReorder,
  onDelete,
}: {
  acc: AccountInfo;
  confirmDel: boolean;
  onAskDel: () => void;
  onClose: () => void;
  onSwitch: () => void;
  onLines: () => void;
  onReorder: () => void;
  onDelete: () => void;
}) {
  return (
    <FocusBoundary className="panel" focusKey="SERVER_MENU">
      <div className="ph">{acc.name}</div>
      <div className="scroll">
        {confirmDel ? (
          <>
            <div className="grp">删除后需要重新登录才能用回这台服务器</div>
            {/* 不可逆操作才给确认框,且**默认焦点在「取消」**。 */}
            <FocusItem className="pitem" autoFocus onEnter={onClose}>
              取消
            </FocusItem>
            <FocusItem className="pitem" onEnter={onDelete}>
              <span style={{ color: "var(--danger)" }}>确认删除</span>
            </FocusItem>
          </>
        ) : (
          <>
            <div className="grp">使用</div>
            <FocusItem
              className={`pitem${acc.active ? " on" : ""}`}
              autoFocus
              onEnter={onSwitch}
            >
              切换到此服务器
              {acc.active && <span className="r">当前</span>}
            </FocusItem>
            <FocusItem className="pitem" onEnter={onLines}>
              线路管理<span className="r">{acc.lines.length} 条 ›</span>
            </FocusItem>

            <div className="grp">编辑</div>
            <FocusItem className="pitem" onEnter={onReorder}>
              调整排序
            </FocusItem>

            {/* 危险项单独分组 + 隔一个组标题,防误触。 */}
            <div className="grp">危险</div>
            <FocusItem className="pitem" onEnter={onAskDel}>
              <span style={{ color: "var(--danger)" }}>删除此服务器</span>
            </FocusItem>
          </>
        )}
      </div>
    </FocusBoundary>
  );
}

/** 把 from 位置的元素搬到 to,其余顺延。核层 reorderAccounts 是同一个语义。 */
function move<T>(list: T[], from: number, to: number): T[] {
  const next = list.slice();
  const [x] = next.splice(from, 1);
  next.splice(to, 0, x);
  return next;
}
