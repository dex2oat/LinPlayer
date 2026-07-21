import { useCallback, useEffect, useState } from "react";
import {
  aggregateSearch,
  fmtRes,
  posterUrl,
  search,
  setActiveServer,
  type Item,
  type LoginResult,
} from "@shared/api";
import type { Route } from "../App";
import { Icon } from "../app/icons";
import { FocusColumn, FocusInput, FocusItem } from "../components/Focus";

/** 搜索(草稿 06)。左 560dp 搜索框+历史,右 1016dp 范围 chip+结果。

    ★ **不自建虚拟键盘**。Android TV 有系统输入法(Leanback IME),输入框拿到 DOM 焦点
      就会从底部升起,还白拿语音输入和外接键盘。自己造一套还得自己维护中文候选。
      代价是**系统键盘会盖住下半屏** —— 所以搜索框和历史都钉在左栏上半屏,
      结果被挡住无所谓(那是打完字才看的),要打的词和历史被挡住就没法用了。
    ★ 历史**不做成结果的空态**:它常驻搜索框正下方,不被结果顶掉。
      结果一出来历史就消失的话,"换个词重搜"就得先把当前的词删干净。
    ★ 「清空」是历史标题右边一个**看得见的按钮**,不藏进菜单键 ——
      菜单键要壳转发(apps/android 还没建),藏起来的功能等于不存在。 */

/* 历史存 localStorage:一个字符串数组,不值当进核层配置。
   key 与桌面端(lp.search.history)**故意分开** —— 客厅遥控器打的词和键盘打的词
   不是一批人在用,混在一起两边的历史都变脏。 */
const HIST_KEY = "lp.tv.search.history";
const HIST_MAX = 8;

/** 输入到发请求的防抖。聚合模式一次要打 N 台服务器,遥控器/IME 逐字上屏时
 *  比键盘慢得多,320ms(桌面值)在这里会连打好几轮。 */
const DEBOUNCE_MS = 400;

type Scope = "current" | "all";

/** 一行结果。serverId 只有聚合模式才有值 —— 进详情前要先切服务器。 */
type Row = { it: Item; from: string | null; serverId: string | null };

const TYPE_LABEL: Record<string, string> = {
  Movie: "电影",
  Series: "剧集",
  Episode: "分集",
  Season: "季",
  BoxSet: "合集",
};

function readHist(): string[] {
  try {
    const v: unknown = JSON.parse(localStorage.getItem(HIST_KEY) ?? "[]");
    /* 逐项校验:这份 JSON 可能被别的版本写过或被手改坏,
       坏了就当空 —— 别让一条脏历史把整页搞崩(透明窗口下 = 一片黑)。 */
    return Array.isArray(v)
      ? v.filter((x): x is string => typeof x === "string").slice(0, HIST_MAX)
      : [];
  } catch {
    return [];
  }
}

function writeHist(next: string[]): string[] {
  try {
    localStorage.setItem(HIST_KEY, JSON.stringify(next));
  } catch {
    /* 配额满/隐私模式:历史丢了不影响搜索本身,不打扰用户 */
  }
  return next;
}

export default function SearchPage({
  session,
  go,
}: {
  session: LoginResult;
  go: (r: Route) => void;
}) {
  const [q, setQ] = useState("");
  /* 防抖后真正拿去搜的词。和 q 分开存,否则每敲一个字都会重跑请求。 */
  const [kw, setKw] = useState("");
  const [scope, setScope] = useState<Scope>("current");
  const [rows, setRows] = useState<Row[] | null>(null);
  const [err, setErr] = useState("");
  /* 初值写成函数,否则每次渲染都读一遍 localStorage。 */
  const [hist, setHist] = useState<string[]>(readHist);

  useEffect(() => {
    const t = window.setTimeout(() => setKw(q.trim()), DEBOUNCE_MS);
    return () => window.clearTimeout(t);
  }, [q]);

  /* 换范围要重搜(草稿:chip 紧贴结果上沿,改范围时结果就在眼皮底下变),
     所以 scope 在依赖里 —— 这点和桌面浮层相反,那边的开关是"只改下次用哪个模式"。
     差别在于:桌面开关拨一下就搜会打 N 台服务器,而这里 chip 是一个明确的
     "现在换个范围看看"的动作,不是顺手拨到的。 */
  useEffect(() => {
    if (!kw) {
      setRows(null);
      setErr("");
      return;
    }
    let alive = true;
    setRows(null);
    setErr("");
    const run = async (): Promise<Row[]> => {
      if (scope === "all") {
        const groups = await aggregateSearch(kw);
        /* ★ **同一部片多台都有时并列显示,不去重**。去重就得挑一台代表,
           而"哪台的版本更好"正是用户点进去要看的东西。 */
        return groups.flatMap((g) =>
          g.items.map((it) => ({ it, from: g.server_name, serverId: g.server_id })),
        );
      }
      const list = await search(kw, undefined, 60);
      return list.map((it) => ({ it, from: null, serverId: null }));
    };
    run()
      .then((r) => alive && setRows(r))
      .catch((e) => {
        if (!alive) return;
        /* 搜挂了和搜不到是两回事,合并成"没有找到结果"就是骗人。 */
        setErr(String(e));
        setRows([]);
      });
    return () => {
      alive = false;
    };
  }, [kw, scope]);

  /* 只在"用户确认了这个词"时记历史 —— 跟着防抖记的话,
     打「幕府将军」会把「幕」「幕府」「幕府将」全记进去。 */
  const remember = useCallback((word: string) => {
    const w = word.trim();
    if (w) setHist((h) => writeHist([w, ...h.filter((x) => x !== w)].slice(0, HIST_MAX)));
  }, []);

  const open = (r: Row) => {
    remember(q);
    /* 聚合结果可能来自别的服务器:不先切服,详情页会拿当前服的 token 去问一个
       不存在的 itemId,表现是"点进去是空白页"。切服失败就别往下走。 */
    if (r.serverId && r.serverId !== session.server) {
      setActiveServer(r.serverId)
        .then(() => go({ page: "detail", itemId: r.it.id }))
        .catch(() => setErr("切换服务器失败"));
      return;
    }
    go({ page: "detail", itemId: r.it.id });
  };

  return (
    <div style={{ display: "flex", gap: 48, height: "100%" }}>
      {/* ---- 左栏 560dp:搜索框 + 历史 ---- */}
      <div style={{ width: 560, flex: "none" }}>
        <FocusColumn focusKey="SEARCH_L">
          {/* 焦点框就是输入框:焦点走到它身上 IME 直接升起,不用先按确认;
              上下键随时离开去点历史。理由见 Focus.tsx 的 FocusInput。
              图标画在框外侧(输入框现在是原生 <input>,塞不进子元素了)。 */}
          <div
            className="field"
            style={{
              marginBottom: 30,
              maxWidth: "none",
              display: "flex",
              alignItems: "center",
              gap: 16,
            }}
          >
            <Icon n="search" className="ic" />
            <FocusInput
              className="in"
              focusKey="SEARCH_INPUT"
              autoFocus
              value={q}
              onChange={setQ}
              placeholder="搜索片名"
              onEnter={() => remember(q)}
              style={{ height: 84, fontSize: 28, borderRadius: 16, flex: 1, minWidth: 0 }}
            />
          </div>

          <div className="rowhead" style={{ marginBottom: 14 }}>
            <div style={{ ...LABEL }}>搜索历史</div>
            {hist.length > 0 && (
              <FocusItem
                className="fchip"
                style={{ marginLeft: "auto", height: 48, fontSize: 16, padding: "0 18px" }}
                onEnter={() => setHist(writeHist([]))}
              >
                <Icon n="trash" className="ic" />
                清空
              </FocusItem>
            )}
          </div>

          {hist.length > 0 && (
            <div className="hist">
              {hist.map((h) => (
                <FocusItem
                  key={h}
                  className="hitem"
                  /* 整行可聚焦,确认即以该词重搜(顺带把它顶到历史第一条)。 */
                  onEnter={() => {
                    setQ(h);
                    setKw(h);
                    remember(h);
                  }}
                >
                  <Icon n="search" className="ic" />
                  {h}
                </FocusItem>
              ))}
            </div>
          )}
        </FocusColumn>
      </div>

      {/* ---- 右栏 1016dp:范围 chip 在上,结果在下 ---- */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <FocusColumn focusKey="SEARCH_R">
          <div className="filters" style={{ marginBottom: 26 }}>
            <ScopeChip on={scope === "current"} label="当前服务器" onEnter={() => setScope("current")} />
            <ScopeChip on={scope === "all"} label="聚合搜索" onEnter={() => setScope("all")} />
          </div>

          {!kw ? (
            <div style={{ ...LABEL }}>输入片名开始搜索</div>
          ) : err ? (
            <div style={{ fontSize: 20, color: "var(--danger)" }}>搜索失败:{err}</div>
          ) : !rows ? (
            <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
              {[0, 1, 2, 3, 4].map((k) => (
                <div key={k} className="sres">
                  <div className="th sk" />
                  <div style={{ flex: 1 }} />
                </div>
              ))}
            </div>
          ) : rows.length === 0 ? (
            <div style={{ fontSize: 20, color: "var(--tv-ink-3)" }}>没有找到结果</div>
          ) : (
            <>
              <div style={{ ...LABEL, marginBottom: 14 }}>结果 · {rows.length}</div>
              <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
                {rows.map((r, i) => (
                  /* key 带上 serverId 和序号:聚合时同一个 itemId 可能在多台服务器上
                     重复出现(我们**故意不去重**),光用 it.id 会撞 key。 */
                  <ResultRow
                    key={`${r.serverId ?? ""}:${r.it.id}:${i}`}
                    row={r}
                    session={session}
                    onEnter={() => open(r)}
                  />
                ))}
              </div>
            </>
          )}
        </FocusColumn>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------ */

const LABEL: React.CSSProperties = {
  fontSize: 16,
  letterSpacing: "0.14em",
  color: "var(--tv-ink-3)",
  fontWeight: 640,
};

function ScopeChip({
  on,
  label,
  onEnter,
}: {
  on: boolean;
  label: string;
  onEnter: () => void;
}) {
  return (
    <FocusItem
      className={`fchip${on ? " on" : ""}`}
      style={{ height: 56, fontSize: 17, padding: "0 22px" }}
      onEnter={onEnter}
    >
      {label}
    </FocusItem>
  );
}

function ResultRow({
  row,
  session,
  onEnter,
}: {
  row: Row;
  session: LoginResult;
  onEnter: () => void;
}) {
  const it = row.it;
  const meta = [
    it.year != null ? String(it.year) : "",
    TYPE_LABEL[it.type_] ?? it.type_,
    fmtRes(it.video_height),
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <FocusItem className="sres" onEnter={onEnter}>
      <div className="th">
        {it.has_primary && <img src={posterUrl(session, it.id, 240)} alt="" loading="lazy" />}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div className="t">{it.name}</div>
        <div className="m">{meta}</div>
      </div>
      {/* 聚合时行尾标来源服务器 —— 不标的话两行同名结果看不出差别在哪。 */}
      {row.from && <div className="from">{row.from}</div>}
    </FocusItem>
  );
}
