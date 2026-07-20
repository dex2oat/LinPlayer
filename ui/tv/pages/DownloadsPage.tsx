import { useCallback, useEffect, useRef, useState } from "react";
import { setFocus } from "@noriginmedia/norigin-spatial-navigation";
import {
  downloadClearCompleted,
  downloadList,
  downloadPause,
  downloadRemove,
  downloadResume,
  downloadSetThreads,
  fmtSize,
  playLocal,
  type DownloadItem,
} from "@shared/api";
import { onTvKey } from "../app/focus";
import { Icon } from "../app/icons";
import { FocusBoundary, FocusColumn, FocusItem } from "../components/Focus";

/** 下载(草稿 10)。

    ★ **整行是焦点单元,行内不放按钮**。一行里塞三个小按钮会让左右键变成噩梦:
      本来"下一个任务"一下就到,变成先横着穿过三个按钮。
    ★ 确认键 = **这一行此刻最常做的那件事**(已完成 → 播放,进行中 → 暂停/继续)。
      删除/线程数这类低频且不可逆的操作收进面板。
    ★ 面板由**菜单键**打开,但「清除已完成 / 线程数」另有一个看得见的入口 ——
      菜单键要 apps/android 的 Activity 转发,壳还没建。躲在拿不到的按键后面的
      能力等于不存在,所以只有"快捷方式"可以挂在菜单键上,不能有独占能力。
      唯一的例外是「删除任务」:它没有别的入口,壳建好前拿不到 —— 见 report。 */

/** 轮询周期。核层没有下载进度事件,只能问。2s 是"进度条看起来在动"和
 *  "别把弱机的主线程刷满"之间的折中,同时也是下面测速的采样间隔。 */
const POLL_MS = 2000;

const THREADS = [1, 2, 3, 4];

export default function DownloadsPage() {
  const [items, setItems] = useState<DownloadItem[] | null>(null);
  const [focused, setFocused] = useState<DownloadItem | null>(null);
  const [menu, setMenu] = useState<DownloadItem | null>(null);
  const [settings, setSettings] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  /* 上一轮的字节数,用来算速度。DownloadItem 里没有速度字段,而"还要多久"是
     这一页唯一真正的信息 —— 光有百分比,用户判断不了该等还是该去睡觉。
     ponytail: 两点差分,精度取决于轮询抖动;要更稳就得核层出速度字段。 */
  const prev = useRef<Map<string, { bytes: number; t: number }>>(new Map());
  const [speed, setSpeed] = useState<Record<string, number>>({});

  const reload = useCallback(() => {
    downloadList()
      .then((list) => {
        const now = Date.now();
        const next: Record<string, number> = {};
        for (const d of list) {
          const p = prev.current.get(d.id);
          if (p && now > p.t && d.received_bytes >= p.bytes)
            next[d.id] = ((d.received_bytes - p.bytes) * 1000) / (now - p.t);
          prev.current.set(d.id, { bytes: d.received_bytes, t: now });
        }
        setSpeed(next);
        setItems(list);
      })
      /* 一次轮询失败不清空列表:闪成空列表比停留在旧数据上更像"下载没了"。 */
      .catch(() => setItems((v) => v ?? []));
  }, []);

  useEffect(() => {
    reload();
    const t = setInterval(reload, POLL_MS);
    return () => clearInterval(t);
  }, [reload]);

  const say = useCallback((m: string) => {
    setToast(m);
    setTimeout(() => setToast(null), 3000);
  }, []);

  const closeSettings = useCallback(() => {
    setSettings(false);
    void setFocus("DL_SETTINGS");
  }, []);

  useEffect(
    () =>
      onTvKey((k) => {
        if (k === "menu") {
          if (!menu && !settings && focused) setMenu(focused);
          return;
        }
        if (k !== "back") return;
        if (menu) setMenu(null);
        else if (settings) closeSettings();
      }),
    [menu, settings, focused, closeSettings],
  );

  /* 确认键:已完成 = 起播本地文件;其余 = 暂停/继续。
     ★ 不 go 到播放页:playLocal 直接让核层的 mpv 起播(TV 的播放页是独立顶层窗口),
       这里再跳一个还没落地的路由只会显示"这一页还没落地"。 */
  const enter = (d: DownloadItem) => {
    if (d.status === "Completed") {
      playLocal(d.id)
        .then(() => say("已开始播放"))
        .catch((e) => say(String(e)));
      return;
    }
    const op = d.status === "Paused" || d.status === "Failed" ? downloadResume : downloadPause;
    op(d.id)
      .then(reload)
      .catch((e) => say(String(e)));
  };

  const active = (items ?? []).filter(
    (d) => d.status !== "Completed" && d.status !== "Canceled",
  );
  const done = (items ?? []).filter((d) => d.status === "Completed");

  return (
    <>
      <FocusColumn focusKey="DL">
        <div style={{ display: "flex", alignItems: "baseline", gap: 20, marginBottom: 8 }}>
          <div className="ptitle" style={{ margin: 0 }}>
            下载
          </div>
          {items && (
            <div style={{ fontSize: 19, color: "var(--tv-ink-3)" }}>
              {active.length} 进行中 · {done.length} 已完成
            </div>
          )}
        </div>
        {/* 草稿这行写的是"已用 42.6 GB · 剩余 118 GB"。**剩余空间核层没有命令**,
            编一个数比不显示更糟(Android TV 内部存储紧张,用户会照着它做决定),
            所以只显示我们真的知道的:已落盘的总量。 */}
        <div className="psub" style={{ marginBottom: 30 }}>
          已下载 {fmtSize((items ?? []).reduce((s, d) => s + d.received_bytes, 0))}
        </div>

        <div className="filters" style={{ alignItems: "center" }}>
          <FocusItem
            focusKey="DL_SETTINGS"
            className="fchip"
            style={{ height: 60, padding: "0 30px" }}
            autoFocus
            onEnter={() => setSettings(true)}
          >
            <Icon n="settings" className="ic" />
            下载设置
          </FocusItem>
          <div style={{ fontSize: 17, color: "var(--tv-ink-3)" }}>
            确认键:已完成播放 / 进行中暂停继续 · 菜单键更多操作
          </div>
        </div>

        {!items ? (
          <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
            {[0, 1, 2].map((k) => (
              <div key={k} style={{ ...ROW }}>
                <div className="sk" style={{ ...THUMB }} />
                <div className="sk" style={{ flex: 1, height: 22 }} />
              </div>
            ))}
          </div>
        ) : items.length === 0 ? (
          <div style={{ paddingTop: 120, textAlign: "center", fontSize: 26, color: "var(--tv-ink-2)" }}>
            还没有下载任务
          </div>
        ) : (
          <>
            {/* 空数组整段不渲染 —— "进行中(空)"只是占位噪音。 */}
            {active.length > 0 && (
              <>
                <div style={{ ...LABEL, marginBottom: 16 }}>进行中</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 14, marginBottom: 30 }}>
                  {active.map((d) => (
                    <Row
                      key={d.id}
                      d={d}
                      bps={speed[d.id]}
                      onFocus={() => setFocused(d)}
                      onEnter={() => enter(d)}
                    />
                  ))}
                </div>
              </>
            )}
            {done.length > 0 && (
              <>
                <div style={{ ...LABEL, marginBottom: 16 }}>已完成</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
                  {done.map((d) => (
                    <Row
                      key={d.id}
                      d={d}
                      onFocus={() => setFocused(d)}
                      onEnter={() => enter(d)}
                    />
                  ))}
                </div>
              </>
            )}
          </>
        )}
      </FocusColumn>

      {settings && (
        <FocusBoundary className="panel" focusKey="DL_SETTINGS_PANEL">
          <div className="ph">下载设置</div>
          <div className="scroll">
            <FocusColumn>
              {/* 核层只有 setter 没有 getter → **不画选中态**。
                  画一个猜出来的勾比不画更糟:它会让人以为当前就是那一档。 */}
              <div className="grp">并发线程</div>
              {THREADS.map((n) => (
                <FocusItem
                  key={n}
                  className="pitem"
                  onEnter={() =>
                    downloadSetThreads(n)
                      .then(() => say(`并发线程已设为 ${n}`))
                      .catch((e) => say(String(e)))
                  }
                >
                  设为 {n} 线程
                </FocusItem>
              ))}

              <div className="grp">清理</div>
              <FocusItem
                className="pitem"
                onEnter={() =>
                  downloadClearCompleted()
                    .then((n) => {
                      say(`已清除 ${n} 条记录`);
                      reload();
                    })
                    .catch((e) => say(String(e)))
                }
              >
                清除已完成记录<span className="r">不删文件</span>
              </FocusItem>
            </FocusColumn>
          </div>
        </FocusBoundary>
      )}

      {menu && (
        <FocusBoundary className="panel" focusKey="DL_MENU">
          <div className="ph">{rowTitle(menu)}</div>
          <div className="scroll">
            {menu.status !== "Completed" && (
              <FocusItem
                className="pitem"
                autoFocus
                onEnter={() => {
                  const d = menu;
                  setMenu(null);
                  enter(d);
                }}
              >
                {menu.status === "Paused" || menu.status === "Failed" ? "继续下载" : "暂停下载"}
              </FocusItem>
            )}
            {menu.status === "Completed" && (
              <FocusItem
                className="pitem"
                autoFocus
                onEnter={() => {
                  const d = menu;
                  setMenu(null);
                  enter(d);
                }}
              >
                播放
              </FocusItem>
            )}
            <div className="grp">危险</div>
            <FocusItem
              className="pitem"
              onEnter={() => {
                const id = menu.id;
                setMenu(null);
                downloadRemove(id)
                  .then(() => {
                    say("已删除任务");
                    reload();
                  })
                  .catch((e) => say(String(e)));
              }}
            >
              <span style={{ color: "var(--danger)" }}>删除任务</span>
            </FocusItem>
          </div>
        </FocusBoundary>
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/* ------------------------------------------------------------ */

const LABEL: React.CSSProperties = {
  fontSize: 16,
  letterSpacing: "0.14em",
  color: "var(--tv-ink-3)",
  fontWeight: 640,
};

const ROW: React.CSSProperties = {
  display: "flex",
  gap: 24,
  alignItems: "center",
  padding: 18,
  borderRadius: 16,
};

const THUMB: React.CSSProperties = {
  width: 160,
  height: 90,
  borderRadius: 10,
  flex: "none",
  overflow: "hidden",
  background: "linear-gradient(135deg, var(--ph), var(--ph-2))",
};

function Row({
  d,
  bps,
  onFocus,
  onEnter,
}: {
  d: DownloadItem;
  bps?: number;
  onFocus: () => void;
  onEnter: () => void;
}) {
  const running = d.status !== "Completed";
  const pct = Math.round(Math.min(1, Math.max(0, d.progress)) * 100);

  return (
    <FocusItem
      className={running ? "" : "dim"}
      style={{
        ...ROW,
        background: running ? "#161a20" : "transparent",
        /* 失败态左侧一条红竖条,不弹窗 —— 弹窗会打断正在浏览列表的人,
           而"哪一条失败了"本来就是扫一眼就要看出来的事。 */
        borderLeft: d.status === "Failed" ? "4px solid var(--danger)" : undefined,
      }}
      onFocus={onFocus}
      onEnter={onEnter}
    >
      <div style={THUMB}>
        {d.poster_url && (
          <img
            src={d.poster_url}
            alt=""
            loading="lazy"
            style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
          />
        )}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 22, fontWeight: 580 }}>{rowTitle(d)}</div>
        <div
          style={{
            fontSize: 16,
            color: "var(--tv-ink-3)",
            margin: running ? "8px 0 12px" : "8px 0 0",
          }}
        >
          {subLine(d, bps)}
        </div>
        {running && (
          <div style={{ height: 6, borderRadius: 3, background: "rgba(255,255,255,.14)" }}>
            <i
              style={{
                display: "block",
                height: "100%",
                width: `${pct}%`,
                background: "var(--accent)",
                borderRadius: 3,
              }}
            />
          </div>
        )}
      </div>
      <div style={{ fontSize: running ? 26 : 18, fontWeight: 640, flex: "none", color: statusColor(d) }}>
        {statusText(d, pct)}
      </div>
    </FocusItem>
  );
}

/** 「剧名 · S1E07 集名」。分集光有集名(常常就是「第 7 集」)在下载列表里认不出是哪部。 */
function rowTitle(d: DownloadItem): string {
  if (d.series_name && d.season_number != null && d.episode_number != null)
    return `${d.series_name} · S${d.season_number}E${String(d.episode_number).padStart(2, "0")} ${d.title}`;
  return d.title;
}

function subLine(d: DownloadItem, bps?: number): string {
  if (d.status === "Completed") return fmtSize(d.total_bytes || d.received_bytes);
  if (d.status === "Failed") return d.error ?? "下载失败";
  const parts = [`${fmtSize(d.received_bytes)} / ${fmtSize(d.total_bytes)}`];
  if (d.status === "Paused") parts.push("已暂停");
  else if (bps && bps > 0) {
    parts.push(`${fmtSize(bps)}/s`);
    const left = d.total_bytes - d.received_bytes;
    if (left > 0) parts.push(`剩 ${fmtEta(left / bps)}`);
  } else if (d.status === "Queued") parts.push("排队中");
  return parts.join(" · ");
}

function statusText(d: DownloadItem, pct: number): string {
  if (d.status === "Completed") return "可离线播放";
  if (d.status === "Failed") return "重试";
  return `${pct}%`;
}

function statusColor(d: DownloadItem): string {
  if (d.status === "Completed") return "var(--good)";
  if (d.status === "Failed") return "var(--danger)";
  return "var(--accent)";
}

/** 剩余时间。**只给到分钟**:秒级数字每两秒跳一次,三米外只会显得页面在抖。 */
function fmtEta(secs: number): string {
  if (!isFinite(secs) || secs <= 0) return "—";
  if (secs < 60) return "不到 1 分钟";
  const m = Math.round(secs / 60);
  if (m < 60) return `${m} 分钟`;
  return `${Math.floor(m / 60)} 小时 ${m % 60} 分钟`;
}
