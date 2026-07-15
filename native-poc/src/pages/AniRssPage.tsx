import { useEffect, useMemo, useState } from "react";
import { type SourceEntry, sourceListDir } from "../lib/api";
import {
  IconChevronLeft,
  IconClose,
  IconPlay,
  IconPlus,
  IconRefresh,
  IconSettings,
  IconTrash,
} from "../app/icons";
import "./AniRssPage.css";

/* ============================================================
   Ani-RSS 追番订阅页(草稿 PAGE 13)。
   内容区顶部分段(首页/订阅/设置)取代移动端底部导航 —— 标注 41。
   数据全部来自已登录 Ani-RSS 源的 sourceListDir(null):根目录 = 番剧列表,
   每条 SourceEntry.raw 携带完整 Ani JSON。零新增后端。
   写操作(增删改订阅)与服务端 Config 表单都缺接口,一律诚实占位,不装成功。
   ============================================================ */

type Seg = "home" | "sub" | "settings";

// Ani-RSS 服务端返回的番剧对象。字段全部可能缺,故一律可空由 aniOf 兜底。
type Ani = {
  title: string;
  image: string | null;
  enable: boolean;
  currentEpisodeNumber: number | null;
  totalEpisodeNumber: number | null;
  week: number | null;
  season: number | null;
  lastDownloadTime: number | null;
  subgroup: string | null;
  score: number | null;
};

type Ctx = { x: number; y: number; ani: Ani };

const WEEK = ["一", "二", "三", "四", "五", "六", "日"];
// 长番(如百集以上)全渲染会刷出几百个格子拖垮列表,超出部分折成 +N。
const EP_CAP = 24;

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

/** 从 SourceEntry 安全读出 Ani;raw 缺字段时回退到 entry 自身的 name/thumb_url。 */
function aniOf(e: SourceEntry): Ani {
  const r = e.raw as Record<string, unknown> | undefined;
  return {
    title: str(r?.title) ?? e.name,
    image: str(r?.image) ?? e.thumb_url,
    // enable 缺省视为 true:Ani-RSS 只在显式暂停时才写 false。
    enable: typeof r?.enable === "boolean" ? r.enable : true,
    currentEpisodeNumber: num(r?.currentEpisodeNumber),
    totalEpisodeNumber: num(r?.totalEpisodeNumber),
    week: num(r?.week),
    season: num(r?.season),
    lastDownloadTime: num(r?.lastDownloadTime),
    subgroup: str(r?.subgroup),
    score: num(r?.score),
  };
}

function fmtDate(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 状态小字:只由真数据推,草稿里的 "E4 下载中 · 62%" 是示意,无后端不编。 */
function statusOf(a: Ani): string {
  if (!a.enable) return "已暂停订阅";
  if (a.week != null && a.week >= 1 && a.week <= 7) {
    const base = `等待更新 · 每周${WEEK[a.week - 1]}`;
    return a.subgroup ? `${base} · ${a.subgroup} 源` : base;
  }
  const last =
    a.lastDownloadTime != null && a.lastDownloadTime > 0
      ? ` · 上次更新 ${fmtDate(a.lastDownloadTime)}`
      : "";
  return `未排期${last}`;
}

export default function AniRssPage({ onBack }: { onBack: () => void }) {
  const [seg, setSeg] = useState<Seg>("sub");
  const [entries, setEntries] = useState<SourceEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [ctx, setCtx] = useState<Ctx | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  const [toast, setToast] = useState("");

  async function load() {
    setEntries(null);
    setErr("");
    setCtx(null);
    try {
      setEntries(await sourceListDir(null));
    } catch (e) {
      setErr(String(e));
      setEntries([]);
    }
  }

  useEffect(() => {
    load();
  }, []);

  // 右键菜单:外部点击/滚动/Esc 关(同 NetdiskPage)。
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
    if (!toast) return;
    const t = setTimeout(() => setToast(""), 2600);
    return () => clearTimeout(t);
  }, [toast]);

  const list = useMemo(() => (entries ?? []).map(aniOf), [entries]);

  // 管理类操作全部需要 Ani-RSS 的 refreshAni/setAni/deleteAni,后端未接。
  function notWired() {
    setCtx(null);
    setToast("该操作需 Ani-RSS 管理接口,后端待接");
  }

  return (
    <>
      <div className="cbar">
        <button className="ibtn" title="返回" onClick={onBack}>
          <IconChevronLeft size={15} />
        </button>
        <span className="crumb">
          <b>Ani-RSS</b>
          {list.length > 0 && <span className="count">· {list.length}</span>}
        </span>
        <span className="push">
          <span className="seg">
            <span
              className={seg === "home" ? "on" : ""}
              onClick={() => setSeg("home")}
            >
              首页
            </span>
            <span
              className={seg === "sub" ? "on" : ""}
              onClick={() => setSeg("sub")}
            >
              订阅
            </span>
            <span
              className={seg === "settings" ? "on" : ""}
              onClick={() => setSeg("settings")}
            >
              设置
            </span>
          </span>
          <button className="btn sm" onClick={() => setAddOpen(true)}>
            <IconPlus size={13} /> 搜索并添加订阅
          </button>
          <button className="ibtn" title="刷新" onClick={load}>
            <IconRefresh size={15} />
          </button>
        </span>
      </div>

      <div className="scroll">
        <div className="cbody">
          {entries == null ? (
            <div className="empty ar-center">
              <span className="spinner" />
            </div>
          ) : err ? (
            <div className="empty">
              未登录 Ani-RSS 源。请在「服务器 › 添加」登录 Ani-RSS 后进入。
              <div className="ar-empty-act">
                <button className="btn" onClick={onBack}>
                  返回服务器
                </button>
              </div>
              <div className="ar-empty-err">{err}</div>
            </div>
          ) : seg === "settings" ? (
            <div className="mdpane ar-pane">
              <h4>Ani-RSS 设置</h4>
              <p className="hint">镜像 Ani-RSS 服务端的配置项。</p>
              <div className="empty">
                镜像 Ani-RSS 服务端 Config 表单需 /api/config 接口,后端待接。
              </div>
            </div>
          ) : list.length === 0 ? (
            <div className="empty">还没有订阅任何番剧。</div>
          ) : seg === "home" ? (
            <div className="ar-wall enter">
              {list.map((a, i) => (
                <div
                  className={`ar-tile${a.enable ? "" : " off"}`}
                  key={`${a.title}-${i}`}
                >
                  <Cover ani={a} className="ar-tile-cv" />
                  <div className="ar-tile-cap">{a.title}</div>
                </div>
              ))}
            </div>
          ) : (
            <div className="enter">
              {list.map((a, i) => (
                <div
                  className="ar-subrow"
                  key={`${a.title}-${i}`}
                  onContextMenu={(ev) => {
                    ev.preventDefault();
                    setCtx({ x: ev.clientX, y: ev.clientY, ani: a });
                  }}
                >
                  <Cover ani={a} className="ar-cv" />
                  <div className="ar-mid">
                    <div className="ar-tt">
                      {a.title}
                      <span className={a.enable ? "ar-on" : "ar-offlbl"}>
                        {a.enable ? " · 启用" : " · 未启用"}
                      </span>
                    </div>
                    <Eps ani={a} />
                    <div className="ar-sub">{statusOf(a)}</div>
                  </div>
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
          <div className="mi" onClick={notWired}>
            <IconRefresh size={15} /> 刷新此订阅
          </div>
          <div className="mi" onClick={notWired}>
            <IconPlay size={15} /> {ctx.ani.enable ? "停用" : "启用"}
          </div>
          <div className="mi" onClick={notWired}>
            <IconSettings size={15} /> 编辑
          </div>
          <div className="mi danger" onClick={notWired}>
            <IconTrash size={15} /> 删除订阅
          </div>
        </div>
      )}

      {addOpen && (
        <div className="scrim" onClick={() => setAddOpen(false)}>
          <div className="dlg" onClick={(e) => e.stopPropagation()}>
            <div className="dhd">
              搜索并添加订阅
              <button className="x" onClick={() => setAddOpen(false)}>
                <IconClose size={15} />
              </button>
            </div>
            <div className="dbd ar-dbd">
              搜索并添加订阅需要 Ani-RSS 的 searchBgm/addAni 接口,后端待接。
            </div>
            <div className="dft">
              <button className="btn" onClick={() => setAddOpen(false)}>
                关闭
              </button>
            </div>
          </div>
        </div>
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/** 封面:有 https 图就用,加载失败或没有就退回全局斜纹占位。 */
function Cover({ ani, className }: { ani: Ani; className: string }) {
  const [bad, setBad] = useState(false);
  if (!ani.image || bad) return <div className={`${className} ph`} />;
  return (
    <img
      className={className}
      src={ani.image}
      alt=""
      loading="lazy"
      onError={() => setBad(true)}
    />
  );
}

/** 逐集格:≤ currentEpisodeNumber 视为已下载。 */
function Eps({ ani }: { ani: Ani }) {
  const total = ani.totalEpisodeNumber ?? ani.currentEpisodeNumber;
  if (total == null || total <= 0) return null;
  const done = ani.currentEpisodeNumber ?? 0;
  const shown = Math.min(total, EP_CAP);
  // ponytail: .dl 态需 /api/torrentsInfos(后端待接),现无数据不标下载中
  return (
    <div className="ar-eps">
      {Array.from({ length: shown }, (_, i) => (
        <span className={`ar-epdot${i + 1 <= done ? " done" : ""}`} key={i}>
          {i + 1}
        </span>
      ))}
      {total > shown && <span className="ar-epmore">+{total - shown}</span>}
    </div>
  );
}
