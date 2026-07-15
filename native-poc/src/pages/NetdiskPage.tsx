import { useEffect, useMemo, useState } from "react";
import { type SourceEntry, sourceListDir } from "../lib/api";
import {
  IconChevronDown,
  IconChevronRight,
  IconDownload,
  IconFile,
  IconFolder,
  IconPlay,
  IconRefresh,
  IconSearch,
} from "../app/icons";
import "./NetdiskPage.css";

/* ============================================================
   网盘 / 文件浏览页 —— 面包屑 + 文件表(草稿 PAGE 12)。
   本页假定已在「服务器 › 添加」登录了某个网盘/文件源;
   进来直接 sourceListDir(null) 列根目录。登录不在本页做,职责单一。
   双击文件夹下钻、双击视频直接播;右键 = 播放/下载/复制链接。
   ============================================================ */

type Crumb = { id: string | null; name: string };
type SortField = "name" | "size";
type Ctx = { x: number; y: number; entry: SourceEntry };

const SUB_EXT = /\.(srt|ass|ssa|sub|vtt|sup|idx)$/i;

function fmtSize(bytes: number | null, isDir: boolean): string {
  if (isDir) return "—";
  if (bytes == null || bytes <= 0) return "—";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let n = bytes;
  let i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`;
}

function kindLabel(e: SourceEntry): string {
  if (e.is_dir) return "文件夹";
  if (e.is_video) return "视频";
  if (SUB_EXT.test(e.name)) return "字幕";
  return "文件";
}

export default function NetdiskPage({
  onPlay,
  onBack,
}: {
  onPlay: (entry: SourceEntry) => void;
  onBack: () => void;
}) {
  // 面包屑栈:根目录起,点第 i 级 slice 回退再 listDir。
  const [trail, setTrail] = useState<Crumb[]>([{ id: null, name: "网盘" }]);
  const [entries, setEntries] = useState<SourceEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [query, setQuery] = useState("");
  const [sortField, setSortField] = useState<SortField>("name");
  const [grid, setGrid] = useState(false);
  const [ctx, setCtx] = useState<Ctx | null>(null);

  const currentId = trail[trail.length - 1]?.id ?? null;

  async function loadDir(dirId: string | null) {
    setEntries(null);
    setErr("");
    setCtx(null);
    try {
      setEntries(await sourceListDir(dirId));
    } catch (e) {
      setErr(String(e));
      setEntries([]);
    }
  }

  // 进页即列根目录。
  useEffect(() => {
    loadDir(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function openDir(entry: SourceEntry) {
    setTrail((t) => [...t, { id: entry.id, name: entry.name }]);
    loadDir(entry.id);
  }

  function goCrumb(i: number) {
    if (i === trail.length - 1) return;
    const c = trail[i];
    setTrail((t) => t.slice(0, i + 1));
    loadDir(c.id);
  }

  function activate(entry: SourceEntry) {
    if (entry.is_dir) openDir(entry);
    else if (entry.is_video) onPlay(entry);
  }

  // 右键菜单:开、随外部点击/滚动/Esc 关。
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

  // 当前目录内搜索 + 排序(文件夹恒置顶)。
  const view = useMemo(() => {
    if (!entries) return [];
    const q = query.trim().toLowerCase();
    const list = q
      ? entries.filter((e) => e.name.toLowerCase().includes(q))
      : entries.slice();
    list.sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      if (sortField === "size") return (a.size ?? 0) - (b.size ?? 0);
      return a.name.localeCompare(b.name, "zh");
    });
    return list;
  }, [entries, query, sortField]);

  function fileIcon(e: SourceEntry) {
    if (e.is_dir) return <IconFolder size={15} />;
    if (e.is_video) return <IconPlay size={13} />;
    return <IconFile size={15} />;
  }

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>网盘</b>
        </span>
        <span className="push">
          <label className="searchbox">
            <IconSearch size={14} />
            <input
              className="nd-search-input"
              placeholder="当前目录搜索…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </label>
          <button
            className="pill"
            title="排序"
            onClick={() =>
              setSortField((f) => (f === "name" ? "size" : "name"))
            }
          >
            排序 · {sortField === "name" ? "名称" : "大小"}
            <IconChevronDown size={12} />
          </button>
          <button
            className={`ibtn${grid ? " on" : ""}`}
            title={grid ? "切到列表" : "切到网格"}
            onClick={() => setGrid((v) => !v)}
          >
            <ViewIcon grid={grid} />
          </button>
          <button className="ibtn" title="刷新" onClick={() => loadDir(currentId)}>
            <IconRefresh size={15} />
          </button>
        </span>
      </div>

      <div className="scroll">
        <div className="nd-body">
          <div className="nd-crumbbar">
            {trail.map((c, i) => (
              <span className="nd-crumb-seg" key={`${c.id ?? "root"}-${i}`}>
                {i > 0 && (
                  <span className="nd-sep">
                    <IconChevronRight size={12} />
                  </span>
                )}
                <button
                  className={`nd-cr${i === trail.length - 1 ? " on" : ""}`}
                  onClick={() => goCrumb(i)}
                >
                  {c.name}
                </button>
              </span>
            ))}
          </div>

          {entries == null ? (
            <div className="nd-loading">
              <div className="spinner" />
            </div>
          ) : err ? (
            <div className="empty nd-empty">
              未登录网盘源。请在「服务器 › 添加」登录网盘 / 文件源后进入。
              <div className="nd-empty-act">
                <button className="btn" onClick={onBack}>
                  前往 服务器 › 添加
                </button>
              </div>
              <div className="nd-empty-err">{err}</div>
            </div>
          ) : view.length === 0 ? (
            <div className="empty">
              {query ? "没有匹配的文件。" : "这个目录是空的。"}
            </div>
          ) : grid ? (
            <div className="nd-grid enter">
              {view.map((e) => (
                <button
                  key={e.id}
                  type="button"
                  className={`nd-cell${e.is_dir ? " nd-dir" : ""}`}
                  disabled={!e.is_dir && !e.is_video}
                  onDoubleClick={() => activate(e)}
                  onContextMenu={(ev) => {
                    ev.preventDefault();
                    setCtx({ x: ev.clientX, y: ev.clientY, entry: e });
                  }}
                >
                  <div className="nd-art">
                    {e.thumb_url ? (
                      <img src={e.thumb_url} loading="lazy" alt="" />
                    ) : e.is_dir ? (
                      <IconFolder size={30} />
                    ) : (
                      <IconFile size={30} />
                    )}
                    {e.is_video && (
                      <span className="nd-play">
                        <IconPlay size={14} />
                      </span>
                    )}
                  </div>
                  <div className="nd-cell-name">{e.name}</div>
                </button>
              ))}
            </div>
          ) : (
            <div className="nd-ftable enter">
              <div className="nd-ftrow head">
                <span>名称</span>
                <span>大小</span>
                <span>修改时间</span>
                <span>类型</span>
              </div>
              {view.map((e) => (
                <div
                  key={e.id}
                  className={`nd-ftrow${e.is_dir || e.is_video ? " tap" : ""}`}
                  onDoubleClick={() => activate(e)}
                  onContextMenu={(ev) => {
                    ev.preventDefault();
                    setCtx({ x: ev.clientX, y: ev.clientY, entry: e });
                  }}
                >
                  <span className="nd-nm">
                    <span className={`nd-fi${e.is_video ? " vid" : ""}`}>
                      {fileIcon(e)}
                    </span>
                    <span className="nd-nm-t">{e.name}</span>
                  </span>
                  <span className="nd-val">{fmtSize(e.size, e.is_dir)}</span>
                  <span className="nd-val">—</span>
                  <span className="nd-val">{kindLabel(e)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {ctx && (
        <div
          className="ctxmenu"
          style={{ left: ctx.x, top: ctx.y }}
          onClick={(e) => e.stopPropagation()}
        >
          {ctx.entry.is_dir ? (
            <div
              className="mi"
              onClick={() => {
                openDir(ctx.entry);
                setCtx(null);
              }}
            >
              <IconFolder size={15} /> 打开
            </div>
          ) : (
            <>
              {ctx.entry.is_video && (
                <div
                  className="mi"
                  onClick={() => {
                    onPlay(ctx.entry);
                    setCtx(null);
                  }}
                >
                  <IconPlay size={15} /> 播放
                </div>
              )}
              {/* 下载 / 复制直链:Rust 核暂无对应命令,诚实禁用。 */}
              <div className="mi nd-mi-off" title="暂未接入">
                <IconDownload size={15} /> 下载
              </div>
              <div className="mi nd-mi-off" title="暂未接入">
                <IconFile size={15} /> 复制链接
              </div>
            </>
          )}
        </div>
      )}
    </>
  );
}

// 网格/列表切换图标(app/icons 无对应,内联,currentColor,不用 emoji)。
function ViewIcon({ grid }: { grid: boolean }) {
  return grid ? (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" aria-hidden>
      <path d="M4 6h16M4 12h16M4 18h16" />
    </svg>
  ) : (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.6} aria-hidden>
      <rect x="3.5" y="3.5" width="7" height="7" rx="1.4" />
      <rect x="13.5" y="3.5" width="7" height="7" rx="1.4" />
      <rect x="3.5" y="13.5" width="7" height="7" rx="1.4" />
      <rect x="13.5" y="13.5" width="7" height="7" rx="1.4" />
    </svg>
  );
}
