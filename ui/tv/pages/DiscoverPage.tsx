import { useMemo, useState } from "react";
import {
  bangumiAccount,
  bangumiCalendar,
  rankingCategories,
  rankingFetch,
  search,
  traktAccount,
  traktCalendar,
  type LoginResult,
  type RankingCategory,
  type RankingEntry,
} from "@shared/api";
import type { Route } from "../App";
import { Icon } from "../app/icons";
import { FocusColumn, FocusItem } from "../components/Focus";
import { useAsync } from "../lib/useAsync";
/* ★ 归组是纯逻辑,而且是**踩过 P0 的**纯逻辑(列数对不上时越界 push 把整页打黑屏,
   见该文件里 groupByWeek 的注释),还有 scripts/check-calendar-grouping.mjs 直接跑它验证。
   TV 端再抄一份日期计算 = 抄一份将来只会在一边被修的 bug。 */
import { groupByWeek, weekOf, weekdayIndex, type Evt } from "@shared/calendar-grouping";

/** 发现(草稿 08 排行榜 + 09 放送表)。

    ★ 导航轨上**只占一格**:PC 侧栏的「排行榜」和「追剧日历」在 TV 上合成这一页。
      遥控器的代价是焦点格数,轨上每多一项,所有下方项都远一格;
      而这两个都是"我不知道看什么"时才进的页,合并后在页内左右切,总按键数更少。
    ★ 左右两栏是两个焦点容器:左栏切分类时右栏内容替换,**焦点留在左栏不跳走** ——
      跟随会让连续浏览分类变得很烦。 */
export default function DiscoverPage({
  go,
}: {
  session: LoginResult;
  go: (r: Route) => void;
}) {
  const [tab, setTab] = useState<"rank" | "cal">("rank");
  const [cat, setCat] = useState<RankingCategory | null>(null);
  const [src, setSrc] = useState<CalSource>("bangumi");
  /* 榜单/放送条目都不是本地库里的 Item,点进去要先在当前服务器搜一遍。
     搜不到就在右栏说一句,不跳去一个什么都没有的详情页。 */
  const [miss, setMiss] = useState<string | null>(null);

  const cats = useAsync(() => rankingCategories(), []);
  const curCat = cat ?? cats.data?.[0] ?? null;

  const open = async (title: string) => {
    setMiss(null);
    try {
      const hits = await search(title, ["Movie", "Series"], 5);
      if (hits.length > 0) go({ page: "detail", itemId: hits[0].id });
      else setMiss(`「${title}」不在当前服务器的媒体库里。`);
    } catch (e) {
      setMiss(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div style={{ display: "flex", height: "100%" }}>
      <div className="master" style={{ width: 360 }}>
        <div className="ptitle" style={{ fontSize: 34, marginBottom: 20 }}>
          发现
        </div>
        <div className="filters" style={{ marginBottom: 24 }}>
          <FocusItem
            className={`fchip${tab === "rank" ? " on" : ""}`}
            style={{ height: 52, fontSize: 17, padding: "0 22px" }}
            autoFocus
            onEnter={() => {
              setTab("rank");
              setMiss(null);
            }}
          >
            排行榜
          </FocusItem>
          <FocusItem
            className={`fchip${tab === "cal" ? " on" : ""}`}
            style={{ height: 52, fontSize: 17, padding: "0 22px" }}
            onEnter={() => {
              setTab("cal");
              setMiss(null);
            }}
          >
            放送表
          </FocusItem>
        </div>

        {/* key 换 tab 即重挂:两个 tab 的左栏是完全不同的列表,复用容器会让
            saveLastFocusedChild 记着一个已经不存在的项。 */}
        {tab === "rank" ? (
          <FocusColumn key="rank" focusKey="DISC_LEFT">
            {(cats.data ?? []).map((c) => (
              <FocusItem
                key={c.id}
                className={`mitem${c.id === curCat?.id ? " on" : ""}`}
                onEnter={() => setCat(c)}
              >
                <Icon n={c.group === "anime" ? "compass" : "library"} className="ic ic-btn" />
                {c.label}
              </FocusItem>
            ))}
          </FocusColumn>
        ) : (
          <FocusColumn key="cal" focusKey="DISC_LEFT">
            {CAL_SOURCES.map((s) => (
              <FocusItem
                key={s.id}
                className={`mitem${s.id === src ? " on" : ""}`}
                onEnter={() => setSrc(s.id)}
              >
                <Icon n="compass" className="ic ic-btn" />
                {s.label}
              </FocusItem>
            ))}
          </FocusColumn>
        )}
      </div>

      <div className="detail">
        {miss && <div style={NOTE}>{miss}</div>}
        {tab === "rank" ? (
          cats.err ? (
            <div style={NOTE}>拉不到榜单分类:{cats.err.message}</div>
          ) : cats.data?.length === 0 ? (
            /* ★ 这里**不存在**什么「排行榜开关」—— 原文写着「默认是关的,去设置里打开」,
               那是 Flutter 时代留下来的说法,Rust 栈里根本没有这个设置项,
               用户照着找只会在设置页里翻个空。分类为空的唯一原因是打包时没注入凭据
               (ranking::available_categories 按 dandan_creds/tmdb_key 过滤)。 */
            <div style={NOTE}>这个安装包没有内置榜单凭据,所以没有可用的榜单。</div>
          ) : curCat ? (
            <RankGrid key={curCat.id} cat={curCat} onOpen={open} />
          ) : (
            <div style={NOTE}>载入中…</div>
          )
        ) : (
          <Calendar key={src} src={src} onOpen={open} />
        )}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------
   排行榜(草稿 08)
   ------------------------------------------------------------ */

function RankGrid({ cat, onOpen }: { cat: RankingCategory; onOpen: (t: string) => void }) {
  const { data, err } = useAsync(() => rankingFetch(cat.id), [cat.id]);

  return (
    <FocusColumn focusKey="DISC_RANK">
      <div style={{ display: "flex", alignItems: "baseline", gap: 16, marginBottom: 26 }}>
        <div style={{ fontSize: 26, fontWeight: 640 }}>{cat.label}</div>
        <div style={{ fontSize: 16, color: "var(--tv-ink-3)" }}>
          {cat.source === "dandan" ? "弹弹play" : "TMDB"}
        </div>
      </div>
      {err ? (
        <div style={NOTE}>拉取失败:{err.message}</div>
      ) : !data ? (
        <div className="grid poster c5">
          {[0, 1, 2, 3, 4].map((k) => (
            <div key={k} className="cell">
              <div className="th sk" />
            </div>
          ))}
        </div>
      ) : data.length === 0 ? (
        /* 空数组整段不画网格 —— 一片灰方块比一句话更难看懂。 */
        <div style={NOTE}>这个榜单现在没有数据。</div>
      ) : (
        <div className="grid poster c5">
          {data.map((e) => (
            <RankCell key={`${e.source}:${e.id}`} e={e} onEnter={() => onOpen(e.title)} />
          ))}
        </div>
      )}
    </FocusColumn>
  );
}

/** 名次角标是这一页和媒体库唯一的视觉差别 —— 没有名次,排行榜就只是另一个网格。
 *  前三名品牌色实心,其余半透明白。 */
function RankCell({ e, onEnter }: { e: RankingEntry; onEnter: () => void }) {
  return (
    <FocusItem className="cell fx" onEnter={onEnter}>
      <div className="th">
        {e.image_url && <img src={e.image_url} alt="" loading="lazy" />}
        <div
          className="badge"
          style={e.rank > 3 ? { background: "rgba(255,255,255,.82)", color: "#0a0c10" } : undefined}
        >
          {e.rank}
        </div>
      </div>
      <div className="nm">{e.title}</div>
      {/* ★ rating 为 null = 没人评过,**不是 0 分**,那就退回副标题,不画一个 ★ 0.0。 */}
      <div className="sub">{e.rating != null ? `★ ${e.rating.toFixed(1)}` : (e.subtitle ?? "")}</div>
    </FocusItem>
  );
}

/* ------------------------------------------------------------
   放送表(草稿 09)
   ------------------------------------------------------------ */

type CalSource = "bangumi" | "trakt";
const CAL_SOURCES: { id: CalSource; label: string }[] = [
  { id: "bangumi", label: "Bangumi 番剧" },
  { id: "trakt", label: "Trakt 剧集" },
];

function Calendar({ src, onOpen }: { src: CalSource; onOpen: (t: string) => void }) {
  /* 同步账号单独一块各自加载:它只用来在空态里说清"是没登录还是真没数据",
     不该把整张放送表堵在它后面。 */
  const acct = useAsync(() => (src === "bangumi" ? bangumiAccount() : traktAccount()), [src]);
  /* onlyMine=false:通用放送表免登录也能看,登录只是让"只看我追的"有意义。 */
  const cal = useAsync(() => (src === "bangumi" ? bangumiCalendar(false) : traktCalendar(false)), [src]);

  const today = useMemo(() => new Date(), []);
  const week = useMemo(() => weekOf(today, 0), [today]);
  const cols = useMemo(
    () => (cal.data ? groupByWeek(cal.data, week) : null),
    [cal.data, week],
  );
  const todayCol = weekdayIndex(today);
  const name = src === "bangumi" ? "Bangumi" : "Trakt";
  const signedIn = acct.data != null;

  if (cal.err)
    return (
      <div style={NOTE}>
        放送表拉取失败:{cal.err.message}
        {!signedIn && `(${name} 账号未登录,可以在设置里绑定)`}
      </div>
    );
  if (!cols) return <div style={NOTE}>载入中…</div>;
  if (cols.every((c) => c.length === 0))
    return (
      <div style={NOTE}>
        {name} 本周没有放送数据。
        {!signedIn && ` 绑定 ${name} 账号后可以只看自己在追的。`}
      </div>
    );

  return (
    <FocusColumn focusKey="DISC_CAL">
      <div style={{ display: "flex", alignItems: "baseline", gap: 20, marginBottom: 8 }}>
        <div className="ptitle" style={{ margin: 0, fontSize: 34 }}>
          放送表
        </div>
        <div style={{ fontSize: 19, color: "var(--tv-ink-3)" }}>
          {fmtDay(week[0])} – {fmtDay(week[6])}
        </div>
      </div>
      <div className="psub" style={{ marginBottom: 26 }}>
        {name}
        {signedIn ? " · 已登录" : " · 未登录(显示通用放送表)"}
      </div>

      {/* 七列。★ 列内**不能上 backdrop-filter**(PC 端踩过:叠加内滚会留残影),
          列背景一律纯色。 */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(7,1fr)", gap: 16 }}>
        {cols.map((col, i) => (
          <div key={i}>
            <div
              style={{
                textAlign: "center",
                padding: "12px 0 16px",
                fontSize: 19,
                color: i === todayCol ? "var(--accent)" : "var(--tv-ink-3)",
                fontWeight: i === todayCol ? 640 : 400,
              }}
            >
              {i === todayCol ? "今天" : WEEKDAYS[i]}
              <div style={{ fontSize: 15, marginTop: 4 }}>{fmtDay(week[i])}</div>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
              {col.map((ev, k) => (
                <CalCard
                  key={`${ev.entry.title}-${k}`}
                  ev={ev}
                  onEnter={() => onOpen(ev.entry.title)}
                />
              ))}
            </div>
          </div>
        ))}
      </div>
    </FocusColumn>
  );
}

/* ★ 卡片**不抢焦点**(草稿写的是"默认焦点落在今天第一项")——
   这一页的入口焦点在左栏,放送表是异步回来的,让它挂载时 focusSelf 会把用户
   刚落在左栏分类上的焦点偷走,而这正是「焦点留在左栏不跳走」明令禁止的。
   今天那一列改用颜色+「今天」标出来。 */
function CalCard({ ev, onEnter }: { ev: Evt; onEnter: () => void }) {
  const e = ev.entry;
  return (
    <FocusItem
      className="fx"
      style={{ borderRadius: 12, overflow: "hidden", background: "#161a20" }}
      onEnter={onEnter}
    >
      <div style={{ height: 132, background: "linear-gradient(135deg,var(--ph),var(--ph-2))" }}>
        {e.image_url && (
          <img
            src={e.image_url}
            alt=""
            loading="lazy"
            style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
          />
        )}
      </div>
      <div style={{ padding: 12 }}>
        <div style={{ fontSize: 16, fontWeight: 560, lineHeight: 1.35 }}>{e.title}</div>
        {/* 时刻取不到就不画 —— 核层拿不到就是拿不到,别编一个播出时间。 */}
        {(e.subtitle || ev.time) && (
          <div style={{ fontSize: 14, color: "var(--tv-ink-3)", marginTop: 6 }}>
            {[e.subtitle, ev.time].filter(Boolean).join(" · ")}
          </div>
        )}
      </div>
    </FocusItem>
  );
}

/* ------------------------------------------------------------ */

const WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
const fmtDay = (d: Date) =>
  `${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}`;

const NOTE: React.CSSProperties = {
  fontSize: 19,
  color: "var(--tv-ink-3)",
  marginBottom: 20,
  maxWidth: 760,
  lineHeight: 1.5,
};
