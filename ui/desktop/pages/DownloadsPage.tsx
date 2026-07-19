import { useEffect, useRef, useState } from "react";
import {
  type DownloadItem,
  downloadClearCompleted,
  downloadList,
  downloadPause,
  downloadRemove,
  downloadResume,
  downloadSetThreads,
} from "@shared/api";
import { IconDownload, IconPause, IconPlay, IconRefresh, IconTrash } from "../app/icons";
import "./DownloadsPage.css";

/* 严格对照 docs/desktop-drafts.html PAGE 11:
   顶栏线程数 stepper + 清除已完成;按剧分组;下载中/已完成两段;每条缩略图+标题+状态+进度条+操作。*/

/* 线程数得前端自己记:download_set_threads 是**只写**的,核层没有 get_threads,
   而引擎的 threads 只活在内存里(crates/core/src/download.rs:DownloadManager::new 写死 threads: 2,
   set_threads 也只改内存、不落盘)。
   所以旧的 useState(3) 是双重撒谎:重启后 pill 显示 3,引擎实际跑的是 2。
   修法 = 存本地 + 挂载时把记住的值回灌引擎,让 pill 与引擎真并发对上。 */
const THREADS_KEY = "dl:threads";

function loadThreads(): number {
  const n = Number(localStorage.getItem(THREADS_KEY));
  return Number.isFinite(n) && n > 0 ? clampThreads(n) : 3;
}

function fmtBytes(n: number): string {
  if (!isFinite(n) || n <= 0) return "0 MB";
  const mb = n / (1024 * 1024);
  if (mb < 1024) return `${mb.toFixed(mb < 10 ? 1 : 0)} MB`;
  return `${(mb / 1024).toFixed(2)} GB`;
}

const pctOf = (it: DownloadItem) =>
  Math.round(Math.min(1, Math.max(0, it.progress)) * 100);

// threads 取顶栏那个全局线程数:download_set_threads 设的就是引擎全局并发(state.download.set_threads),
// DownloadItem 上没有逐条线程字段,所以下载中的条目用全局值是如实的,不是编的。
function subText(it: DownloadItem, speed: number | undefined, threads: number): string {
  const pct = pctOf(it);
  switch (it.status) {
    case "Downloading":
      return speed
        ? `下载中 · ${threads} 线程 · ${fmtBytes(speed)}/s · ${pct}%`
        : `下载中 · ${threads} 线程 · ${pct}%`;
    case "Queued":
      return "排队中…";
    case "Paused":
      return `已暂停 · ${pct}%`;
    case "Completed":
      return `已完成 · ${fmtBytes(it.total_bytes || it.received_bytes)}`;
    case "Failed":
      return it.error ? `失败 · ${it.error}` : "失败";
    case "Canceled":
      return "已取消";
  }
}

// 剧集标题:有集号 → SxEy + 集名,否则用整条 title(电影)。
function rowTitle(it: DownloadItem): string {
  if (it.episode_number != null) {
    const s = it.season_number ?? 1;
    return `S${s}E${it.episode_number} ${it.title}`;
  }
  return it.title;
}

// 段内分块:同剧名聚成一块(保首现顺序),电影/无剧名各成单条。
type Block =
  | { kind: "single"; item: DownloadItem }
  | { kind: "series"; name: string; season: number | null; items: DownloadItem[] };

function toBlocks(items: DownloadItem[]): Block[] {
  const blocks: Block[] = [];
  const idxOf = new Map<string, number>();
  for (const it of items) {
    if (it.series_name) {
      const at = idxOf.get(it.series_name);
      if (at == null) {
        idxOf.set(it.series_name, blocks.length);
        blocks.push({ kind: "series", name: it.series_name, season: it.season_number, items: [it] });
      } else {
        (blocks[at] as Extract<Block, { kind: "series" }>).items.push(it);
      }
    } else {
      blocks.push({ kind: "single", item: it });
    }
  }
  return blocks;
}

function clampThreads(n: number): number {
  return Math.min(4, Math.max(1, n));
}

type Ctx = { x: number; y: number; item: DownloadItem };

export default function DownloadsPage({
  onPlayLocal,
}: {
  /** 起播已下完的本地文件。**必须由 Shell 注入** —— 原因见下方 playRow 注释。 */
  onPlayLocal?: (item: DownloadItem) => void;
} = {}) {
  const [items, setItems] = useState<DownloadItem[] | null>(null);
  const [threads, setThreads] = useState(loadThreads);
  const [speed, setSpeed] = useState<Record<string, number>>({});
  const [err, setErr] = useState("");
  const [toast, setToast] = useState("");
  const [ctx, setCtx] = useState<Ctx | null>(null);
  const prevRef = useRef<Map<string, { bytes: number; t: number }>>(new Map());

  // 把记住的线程数回灌引擎:只写命令 + 引擎每次启动都是默认值,不回灌 pill 就与实际并发不符。
  useEffect(() => {
    downloadSetThreads(loadThreads()).catch((e) => setErr(String(e)));
  }, []);

  // 右键菜单:外部点击/滚动/Esc 关(同 NetdiskPage 的约定)。
  useEffect(() => {
    if (!ctx) return;
    const close = () => setCtx(null);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setCtx(null);
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("keydown", onKey);
    };
  }, [ctx]);

  useEffect(() => {
    let alive = true;
    const refresh = async () => {
      try {
        const list = await downloadList();
        if (!alive) return;
        // 相邻两轮(≈1s)received_bytes 差 → 估算速率。
        const now = Date.now();
        const prev = prevRef.current;
        const sp: Record<string, number> = {};
        const next = new Map<string, { bytes: number; t: number }>();
        for (const it of list) {
          const p = prev.get(it.id);
          if (p && now > p.t && it.status === "Downloading") {
            const bps = (it.received_bytes - p.bytes) / ((now - p.t) / 1000);
            if (bps > 0) sp[it.id] = bps;
          }
          next.set(it.id, { bytes: it.received_bytes, t: now });
        }
        prevRef.current = next;
        setItems(list);
        setSpeed(sp);
        setErr("");
      } catch (e) {
        if (alive) setErr(String(e));
      }
    };
    refresh();
    const timer = setInterval(refresh, 1000);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(""), 2600);
    return () => window.clearTimeout(t);
  }, [toast]);

  /* 播放已下载的本地文件(草稿标注 38:▶ + 双击)。
     后端**有**这个命令:play_local(id, resumeSecs) 收任务 id(不是路径),
     内部 completed_path(&id) 解析路径 + 校验文件还在,返回起播秒数。

     但起播不能由本页发起:mpv 的视频窗口被 sync_overlay 垫在 Tauri 窗口**下面**,
     只有 App 把 .app-root 切成 hidden(即 setPlaying(...))才露得出画面和 OSD。
     本页只在 Shell 注入 onPlayLocal 时才起播 —— 与 NetdiskPage 把 onPlay 交给 App 的做法一致。
     没注入就如实说:绝不偷偷起一个"只有声音、没有画面、还关不掉"的播放。 */
  const playRow = (it: DownloadItem) => {
    setCtx(null);
    if (onPlayLocal) {
      onPlayLocal(it);
      return;
    }
    setToast("播放已完成 — 需 Shell 注入 onPlayLocal(播放器界面归 App 管,本页起播会没有画面)");
  };

  const setThreadsClamped = (n: number) => {
    const v = clampThreads(n);
    setThreads(v);
    localStorage.setItem(THREADS_KEY, String(v));
    downloadSetThreads(v).catch((e) => setErr(String(e)));
  };

  const act = (fn: (id: string) => Promise<void>, id: string) => {
    setCtx(null);
    return fn(id).catch((e) => setErr(String(e)));
  };

  /* 「清除已完成」只清记录,不删文件。
     ★ 别再改回逐条 downloadRemove —— 那个命令会 delete_files 把用户已下好的片子真删掉,
     与本按钮的语义正相反(想删文件的是每条右边那个 ✕)。核层 download_clear_completed
     走的是 forget(只丢记录),返回清掉的条数。 */
  const clearCompleted = () => {
    setCtx(null);
    downloadClearCompleted()
      .then((n) => setToast(`已清除 ${n} 条已完成记录(文件保留)`))
      .catch((e) => setErr(String(e)));
  };

  const list = items ?? [];
  const active = list.filter((it) => it.status !== "Completed");
  const completed = list.filter((it) => it.status === "Completed");

  // 剧集全局计数(共 N 集 · 已完成 M),跨段统计。
  const seriesTotals = new Map<string, { total: number; done: number }>();
  for (const it of list) {
    if (!it.series_name) continue;
    const c = seriesTotals.get(it.series_name) ?? { total: 0, done: 0 };
    c.total += 1;
    if (it.status === "Completed") c.done += 1;
    seriesTotals.set(it.series_name, c);
  }

  const renderRow = (it: DownloadItem) => {
    const pct = pctOf(it);
    const barMod = it.status === "Completed" ? "done" : it.status === "Failed" ? "fail" : "";
    const done = it.status === "Completed";
    return (
      // 标注 38:完成项双击播放 + 右键菜单。
      <div
        className="dl-tsk"
        key={it.id}
        onDoubleClick={done ? () => playRow(it) : undefined}
        onContextMenu={(ev) => {
          ev.preventDefault();
          setCtx({ x: ev.clientX, y: ev.clientY, item: it });
        }}
      >
        <div className="dl-th">
          {it.poster_url ? (
            <img src={it.poster_url} loading="lazy" alt="" />
          ) : (
            <IconDownload size={18} />
          )}
        </div>
        <div className="dl-mid">
          <span className="dl-tt">{rowTitle(it)}</span>
          <span className={it.status === "Failed" ? "dl-sub err" : "dl-sub"}>
            {subText(it, speed[it.id], threads)}
          </span>
          <span className="dl-bar">
            <i className={barMod} style={{ width: `${pct}%` }} />
          </span>
        </div>
        <div className="dl-acts">
          {/* 草稿 L1582:已完成条目是「▶ ✕」两个按钮,之前只做了删除,▶ 漏了。 */}
          {done && (
            <button className="ibtn" title="播放" onClick={() => playRow(it)}>
              <IconPlay size={15} />
            </button>
          )}
          {it.status === "Downloading" && (
            <button className="ibtn" title="暂停" onClick={() => act(downloadPause, it.id)}>
              <IconPause size={15} />
            </button>
          )}
          {(it.status === "Paused" || it.status === "Queued") && (
            <button className="ibtn" title="继续" onClick={() => act(downloadResume, it.id)}>
              <IconPlay size={15} />
            </button>
          )}
          {(it.status === "Failed" || it.status === "Canceled") && (
            <button className="ibtn" title="重试" onClick={() => act(downloadResume, it.id)}>
              <IconRefresh size={15} />
            </button>
          )}
          <button className="ibtn" title="删除" onClick={() => act(downloadRemove, it.id)}>
            <IconTrash size={15} />
          </button>
        </div>
      </div>
    );
  };

  const renderBlocks = (sectionItems: DownloadItem[]) =>
    toBlocks(sectionItems).map((b) => {
      if (b.kind === "single") return renderRow(b.item);
      const tot = seriesTotals.get(b.name);
      const head = b.season != null ? `${b.name} · 第 ${b.season} 季` : b.name;
      return (
        <div key={`s:${b.name}`}>
          <div className="dl-grouphd sub">
            <span className="h">{head}</span>
            {tot && <span className="c">共 {tot.total} 集 · 已完成 {tot.done}</span>}
          </div>
          {b.items.map(renderRow)}
        </div>
      );
    });

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>下载</b>
        </span>
        <span className="push">
          <span className="pill">
            线程数
            <span className="stepper" style={{ marginLeft: 6 }}>
              <span
                className="b"
                role="button"
                onClick={() => setThreadsClamped(threads - 1)}
              >
                −
              </span>
              <span className="v">{threads}</span>
              <span
                className="b"
                role="button"
                onClick={() => setThreadsClamped(threads + 1)}
              >
                ＋
              </span>
            </span>
          </span>
          <button className="btn sm" onClick={clearCompleted} disabled={completed.length === 0}>
            清除已完成
          </button>
        </span>
      </div>

      {err && <div className="toast error">{err}</div>}

      <div className="scroll">
        {items === null ? (
          <div className="empty">
            <span className="spinner" />
          </div>
        ) : list.length === 0 ? (
          <div className="empty">暂无下载任务。下载从条目详情页发起。</div>
        ) : (
          <div className="dl-list">
            {active.length > 0 && (
              <>
                <div className="dl-grouphd head">
                  <span className="h">下载中</span>
                  <span className="c">{active.length}</span>
                </div>
                {renderBlocks(active)}
              </>
            )}
            {completed.length > 0 && (
              <>
                <div className="dl-grouphd head">
                  <span className="h">已完成</span>
                  <span className="c">{completed.length}</span>
                </div>
                {renderBlocks(completed)}
              </>
            )}
          </div>
        )}
        <div style={{ height: 40 }} />
      </div>

      {/* 标注 38:右键 = 菜单。项按状态给,不给当前状态下无意义的动作。 */}
      {ctx && (
        <div
          className="ctxmenu"
          style={{ left: ctx.x, top: ctx.y }}
          onClick={(e) => e.stopPropagation()}
        >
          {ctx.item.status === "Completed" && (
            <div className="mi" onClick={() => playRow(ctx.item)}>
              <IconPlay size={15} /> 播放
            </div>
          )}
          {ctx.item.status === "Downloading" && (
            <div className="mi" onClick={() => act(downloadPause, ctx.item.id)}>
              <IconPause size={15} /> 暂停
            </div>
          )}
          {(ctx.item.status === "Paused" || ctx.item.status === "Queued") && (
            <div className="mi" onClick={() => act(downloadResume, ctx.item.id)}>
              <IconPlay size={15} /> 继续
            </div>
          )}
          {(ctx.item.status === "Failed" || ctx.item.status === "Canceled") && (
            <div className="mi" onClick={() => act(downloadResume, ctx.item.id)}>
              <IconRefresh size={15} /> 重试
            </div>
          )}
          {/* ✕ 与本项一样:download_remove 会连文件一起删,所以写明「并删除文件」。 */}
          <div className="mi danger" onClick={() => act(downloadRemove, ctx.item.id)}>
            <IconTrash size={15} /> 删除(含文件)
          </div>
        </div>
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
