import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  type CalendarEntry,
  type Item,
  afdianSponsorUrl,
  afdianVerify,
  bangumiCalendar,
  bangumiSummary,
  traktCalendar,
} from "../lib/api";
import { IconChevronLeft, IconChevronRight } from "../app/icons";
/* 归组是纯逻辑,拆去 calendar-grouping.ts —— 那边能被 scripts/check-calendar-grouping.mjs 真跑到。 */
import {
  type Evt,
  type St,
  dayKey,
  groupByWeek,
  statusOf,
  weekOf,
  weekdayIndex,
} from "./calendar-grouping";
import { SourcePicker } from "./RankingsPage";
import "./CalendarPage.css";

type Source = "trakt" | "bangumi";
/** 本周(七列周视图)/ 本日(单日时间轴)。用户 2026-07-16:「本周太多了 信息处理不过来」。 */
type View = "week" | "day";

const WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
// 软锁:存校验通过的订单号即视为已解锁,不每次联网重校(爱发电校验要网络)。
const LOCK_KEY = "cal:afdian";
/* 赞助下单页地址来自核层(afdianSponsorUrl 命令),**不在这里硬编**。
   2026-07-19 就是栽在这:这里曾写死一个凭空猜的爱发电主页(用项目名当用户名),
   而核层 `AFDIAN_SPONSOR_URL` 一直是对的。那个页面不是作者本人的,点「前往爱发电
   赞助」的人全被送错地方 —— 功能看着完全正常,赞助收益却是零。
   收款地址必须只有一份;守卫测试 frontend_never_hardcodes_a_sponsor_url 钉着它。 */

/* 追剧日历(用户 2026-07-16):
   - 提到侧栏(见 nav.ts),不再藏在 设置 里。
   - 仍是**付费功能**:爱发电赞助后用订单号软锁解锁本机(用户明确要「肯定还要付费才能用」)。
   - 解锁之后:默认 Bangumi + 不看我追的 —— 后端公开 /calendar 免 Bangumi 登录即返回整张放送表,
     所以「解锁后哪怕不登录账号也能看正常每周放送表」。「只看我追的」才需要在设置里登录对应账号。 */
export default function CalendarPage({
  onOpenItem,
}: {
  /** 点卡片跨服找到片源后直接开详情(Shell 传 openFromSearch)。不传就只切服务器 + 提示。 */
  onOpenItem?: (item: Item, serverId: string) => void;
}) {
  const [unlocked, setUnlocked] = useState(() => !!localStorage.getItem(LOCK_KEY));
  const [source, setSource] = useState<Source>("bangumi");
  const [onlyMine, setOnlyMine] = useState(false);
  const [weekOffset, setWeekOffset] = useState(0);
  /* 视图 + 日偏移。两个视图各有各的偏移(周视图翻周、日视图翻天),
     共用一个偏移量的话「从周三切到本周再切回来」会莫名其妙跳到别的周。 */
  const [view, setView] = useState<View>("day");
  const [dayOffset, setDayOffset] = useState(0);
  const [entries, setEntries] = useState<CalendarEntry[] | null>(null);
  const [toast, setToast] = useState<{ msg: string; error?: boolean } | null>(null);
  const [orderNo, setOrderNo] = useState("");
  const [verifying, setVerifying] = useState(false);
  // 点卡片 → 跨服找可播源(草稿 44),与排行榜共用同一个弹窗。
  const [pick, setPick] = useState<string | null>(null);

  const say = useCallback((msg: string, error?: boolean) => {
    setToast({ msg, error });
    setTimeout(() => setToast(null), 3200);
  }, []);

  // 未解锁不拉数据;来源/只看我追的 变了就重拉(周切换是纯前端归组,不必回后端)。
  useEffect(() => {
    if (!unlocked) return;
    let alive = true;
    setEntries(null);
    (async () => {
      try {
        const list =
          source === "trakt" ? await traktCalendar(onlyMine) : await bangumiCalendar(onlyMine);
        if (alive) setEntries(list);
      } catch (e) {
        if (alive) {
          setEntries([]);
          say(String(e), true);
        }
      }
    })();
    return () => {
      alive = false;
    };
  }, [unlocked, source, onlyMine, say]);

  const onUnlock = async () => {
    const no = orderNo.trim();
    if (!no || verifying) return;
    setVerifying(true);
    try {
      const r = await afdianVerify(no);
      if (r.valid) {
        localStorage.setItem(LOCK_KEY, no);
        setUnlocked(true);
        say(`已解锁：${r.plan_title}（${r.amount}）`);
      } else {
        say(r.reason ?? "订单号无效", true);
      }
    } catch (e) {
      say(String(e), true);
    } finally {
      setVerifying(false);
    }
  };

  const week = weekOf(new Date(), weekOffset);
  const todayKey = dayKey(new Date());
  /* ★ 必须 memo。这里曾是裸调用 —— **每渲染一次就产出一个全新数组**,
     而 DayFocus 里 `useEffect(..., [evts])` 的本意是「列表变了就把焦点重新定位到现在」。
     结果:点一下卡片 → setPick → CalendarPage 重渲染 → dayEvts 换了身份 → effect 触发
     → 焦点被打回「现在」那条 —— 用户看到的就是「点卡片弹出查找时,卡片自己往上/往下跑」。
     依赖只认真正会改变内容的东西:数据本身 + 看的是哪一周/哪一天。 */
  const cols = useMemo(
    () => groupByWeek(entries ?? [], week),
    // week 每次都是新数组,不能进依赖;weekOffset 才是它的真实自变量。
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [entries, weekOffset],
  );
  const weekLabel =
    weekOffset === 0
      ? "本周"
      : `${week[0].getMonth() + 1}月${week[0].getDate()}日 – ${week[6].getMonth() + 1}月${week[6].getDate()}日`;

  const theDay = (() => {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() + dayOffset);
    return d;
  })();
  /* 日视图 = 拿 theDay 所在的**整周**跑归组,再取它那一列。
     ★ 别图省事传 `[theDay]`:groupByWeek 的 weekday 分支按绝对星期几索引 7 列,
       短数组会让它越界写 undefined → 整页黑屏(2026-07-16 真炸过,见该函数注释)。 */
  const dayEvts = useMemo(
    () => groupByWeek(entries ?? [], weekOf(theDay, 0))[weekdayIndex(theDay)],
    // 同上:theDay 每次都是新 Date 对象,真正的自变量是 dayOffset。
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [entries, dayOffset],
  );
  const dayLabel =
    dayOffset === 0
      ? "今天"
      : dayOffset === 1
        ? "明天"
        : dayOffset === -1
          ? "昨天"
          : `${theDay.getMonth() + 1}月${theDay.getDate()}日 · ${WEEKDAYS[weekdayIndex(theDay)]}`;
  // 空态文案要跟着当前视图走:日视图下报「本周没有」会让人以为翻页也没用。
  const total = view === "week" ? cols.reduce((n, c) => n + c.length, 0) : dayEvts.length;

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>追剧日历</b>
          {unlocked && <span className="cal-lock-tag">· 已解锁</span>}
        </span>
        {unlocked && (
          <span className="push">
            <span className="seg">
              <span className={source === "bangumi" ? "on" : undefined} onClick={() => setSource("bangumi")}>
                Bangumi
              </span>
              <span className={source === "trakt" ? "on" : undefined} onClick={() => setSource("trakt")}>
                Trakt
              </span>
            </span>
            <span className="pill" onClick={() => setOnlyMine((v) => !v)}>
              只看我追的
              <span className={onlyMine ? "sw on" : "sw"}>
                <i />
              </span>
            </span>
            {/* 本周 / 本日(用户 2026-07-16:「本周太多了 信息处理不过来」)。 */}
            <span className="seg">
              <span className={view === "day" ? "on" : undefined} onClick={() => setView("day")}>
                本日
              </span>
              <span className={view === "week" ? "on" : undefined} onClick={() => setView("week")}>
                本周
              </span>
            </span>
            {view === "week" ? (
              <>
                <button type="button" className="ibtn" title="上一周" onClick={() => setWeekOffset((w) => w - 1)}>
                  <IconChevronLeft size={15} />
                </button>
                <span className="pill" title="回到本周" onClick={() => setWeekOffset(0)}>
                  {weekLabel}
                </span>
                <button type="button" className="ibtn" title="下一周" onClick={() => setWeekOffset((w) => w + 1)}>
                  <IconChevronRight size={15} />
                </button>
              </>
            ) : (
              <>
                <button type="button" className="ibtn" title="前一天" onClick={() => setDayOffset((d) => d - 1)}>
                  <IconChevronLeft size={15} />
                </button>
                <span className="pill" title="回到今天" onClick={() => setDayOffset(0)}>
                  {dayLabel}
                </span>
                <button type="button" className="ibtn" title="后一天" onClick={() => setDayOffset((d) => d + 1)}>
                  <IconChevronRight size={15} />
                </button>
              </>
            )}
          </span>
        )}
      </div>

      <div className="scroll">
        <div className="cbody">
          {!unlocked ? (
            <div className="cal-gate">
              <div className="cal-gate-h">追剧日历 · 赞助解锁</div>
              <div className="cal-gate-p">这是付费功能。在爱发电赞助后，用订单号解锁本机。</div>
              <div className="cal-gate-row">
                <input
                  className="field"
                  placeholder="爱发电订单号"
                  value={orderNo}
                  onChange={(e) => setOrderNo(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && onUnlock()}
                />
                <button
                  type="button"
                  className="btn primary"
                  onClick={onUnlock}
                  disabled={verifying || !orderNo.trim()}
                >
                  解锁
                </button>
              </div>
              <div className="cal-gate-row">
                <button
                  type="button"
                  className="btn"
                  onClick={() =>
                    // 外部浏览器打开:app 内没有浏览器壳,塞进 webview 只会把人困在 webview 里。
                    // 失败要说出来 —— 静默失败会让用户以为按钮是坏的(本仓最烂的 bug 类型)。
                    void afdianSponsorUrl()
                      .then((u) => openUrl(u).catch(() => say(`打不开浏览器，请手动访问 ${u}`, true)))
                      // 地址取不到就别猜一个 —— 猜错等于把赞助送给别人。
                      .catch((e) => say(`取赞助地址失败：${e}`, true))
                  }
                >
                  前往爱发电赞助
                </button>
              </div>
              <div className="caption-note cal-gate-note">
                赞助后在爱发电订单详情复制订单号，填入上方解锁本机。
              </div>
            </div>
          ) : entries == null ? (
            <div className="empty">
              <span className="spinner" />
            </div>
          ) : (
            <>
              {total === 0 && (
                <div className="caption-note cal-gate-note">
                  {onlyMine
                    ? "「只看我追的」为空 —— 需在 设置 › Bangumi / Trakt 登录并标记在看,或关掉此开关看整张放送表。"
                    : view === "day"
                      ? `${dayLabel}没有放送。`
                      : "本周没有放送数据(放送表可能暂时取不到,稍后再试)。"}
                </div>
              )}
              {/* 本日 = 直列表(按时间);本周 = 看板(参考 B 站放送表)。
                  两个视图定位不同:本日重「今天几点更什么」,本周重「一眼扫完整周」。 */}
              {view === "day" ? (
                <div className="cal-tl">
                  <DayList key={dayKey(theDay)} day={theDay} label={dayLabel} evts={dayEvts} onPick={setPick} />
                </div>
              ) : (
                <WeekBoard
                  week={week}
                  cols={cols}
                  todayKey={todayKey}
                  // 换周要重挂:滚动位置得重新定(新的一周里「今天」在不在、在哪都变了)。
                  key={dayKey(week[0])}
                  onPick={setPick}
                />
              )}
            </>
          )}
        </div>
      </div>

      {pick && <SourcePicker title={pick} onOpenItem={onOpenItem} onClose={() => setPick(null)} />}

      {toast && <div className={toast.error ? "toast error" : "toast"}>{toast.msg}</div>}
    </>
  );
}

/* ============================================================
   本日 · 直列表(用户 2026-07-17:「取消堆叠,堆叠不方便,直接列表按时间列出来,
   未定的放最下面就行」)。

   曾经历三版:变焦(浪费信息量)→ 小时档堆叠(悬停展开,用户嫌不方便)→ 现在这版最简单:
   一条一行、按时间从早到晚、待定沉底。dayEvts 已由 groupByWeek 排好(升序 + 无时刻殿后),
   这里直接铺,不再分档、不再堆。本日有整行宽度,所以简介直接内联展示,不藏在悬停后面。
   ============================================================ */
function DayList({
  day,
  label,
  evts,
  onPick,
}: {
  day: Date;
  label: string;
  evts: Evt[];
  onPick: (title: string) => void;
}) {
  const now = new Date();
  const nowMin = now.getHours() * 60 + now.getMinutes();
  const today0 = new Date(now);
  today0.setHours(0, 0, 0, 0);
  const dayCmp = Math.sign(day.getTime() - today0.getTime());

  if (evts.length === 0) return null;

  return (
    <div className="cal-list">
      <div className="cal-dsec-hd solo">
        <span className="cal-dsec-d">{day.getDate()}</span>
        <span className="cal-dsec-t">{label}</span>
        <span className="cal-dsec-c">{evts.length} 部放送</span>
      </div>
      {evts.map((ev, i) => (
        <DayRow
          key={`${ev.entry.title}-${i}`}
          evt={ev}
          st={statusOf(ev.time, nowMin, dayCmp)}
          onClick={() => onPick(ev.entry.title)}
        />
      ))}
    </div>
  );
}

/** 本日的一行:时刻 + 封面 + 标题/状态/评分 + 内联简介。整行宽,信息一次铺开,不用展开。 */
function DayRow({ evt, st, onClick }: { evt: Evt; st: St; onClick: () => void }) {
  const { entry } = evt;
  const [loaded, setLoaded] = useState(false);
  return (
    <div
      className={`cal-lrow${st === "past" ? " past" : ""}${st === "airing" ? " airing" : ""}`}
      onClick={onClick}
      title={`跨服查找可播源 · ${entry.title}`}
    >
      <span className="cal-ltime">{evt.time ?? "待定"}</span>
      <div className="cal-lth">
        {entry.image_url && !loaded && <div className="cal-skel skeleton" />}
        {entry.image_url ? (
          <img
            className={`cal-limg${loaded ? " ready" : ""}`}
            src={entry.image_url}
            alt={entry.title}
            loading="lazy"
            decoding="async"
            onLoad={() => setLoaded(true)}
            onError={(ev) => {
              setLoaded(true);
              (ev.target as HTMLImageElement).style.visibility = "hidden";
            }}
          />
        ) : (
          <span className="cal-limg ph" />
        )}
      </div>
      <div className="cal-ltxt">
        <div className="cal-lhd">
          <span className="cal-lt1">{entry.title}</span>
          {st === "airing" && <span className="cal-lst">正在播出</span>}
          {/* 评分:核层给的真字段。null = 没人评过 → 不画(画成 0.0 等于诽谤)。 */}
          {entry.rating != null && (
            <span className={`rate${entry.rating >= 8 ? " hi" : ""}`}>
              <i className="s">★</i>
              {entry.rating.toFixed(1)}
            </span>
          )}
        </div>
        {entry.subtitle && <span className="cal-lsub">{entry.subtitle}</span>}
        {/* 简介内联(本日有整行宽度)。按需拉,取不到不占位、不编。 */}
        <CalSummary entry={entry} />
      </div>
    </div>
  );
}

function WeekBoard({
  week,
  cols,
  todayKey,
  onPick,
}: {
  week: Date[];
  cols: Evt[][];
  todayKey: string;
  onPick: (title: string) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  // 到头/到尾时箭头置灰(B 站是 .hidden 直接藏;置灰不会让按钮跳走,手更稳)。
  const [edge, setEdge] = useState({ left: false, right: true });

  const sync = useCallback(() => {
    const el = ref.current;
    if (!el) return;
    setEdge({
      left: el.scrollLeft > 4,
      // 留 4px 容差:缩放比例非整数时 scrollWidth 会差出零点几像素,
      // 卡死等号会让右箭头在滚到底时永远不灰(或永远灰)。
      right: el.scrollLeft + el.clientWidth < el.scrollWidth - 4,
    });
  }, []);

  /* 今天居中(用户 2026-07-16:「今天的放送表应该是居中的 而不是靠边的」)。
     ★ 必须等布局出来才能算:列宽是 clamp(…,22vw,…),首帧拿到的 offsetLeft 可能还是 0。
       用 requestAnimationFrame 推到下一帧,那时 layout 已经跑完。 */
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const id = requestAnimationFrame(() => {
      const col = el.querySelector<HTMLElement>(".cal-bcol.today");
      if (col) {
        // 居中 = 让这一列的中点对上视口中点;浏览器会自动 clamp 到 [0, max],
        // 所以周一/周日是今天时它会自然靠边 —— 那是没得居中,不是 bug。
        el.scrollLeft = col.offsetLeft - (el.clientWidth - col.clientWidth) / 2;
      }
      sync();
    });
    return () => cancelAnimationFrame(id);
  }, [sync]);

  const page = (dir: -1 | 1) => {
    const el = ref.current;
    if (!el) return;
    const col = el.querySelector<HTMLElement>(".cal-bcol");
    // 一次翻一列(含 gap)。取真实列宽,不写死 —— 列宽是 clamp 出来的,随窗口变。
    const step = col ? col.clientWidth + 14 : 300;
    el.scrollBy({ left: dir * step, behavior: "smooth" });
  };

  return (
    <div className="cal-boardwrap">
      <button
        type="button"
        className="cal-arrow l"
        title="前几天"
        disabled={!edge.left}
        onClick={() => page(-1)}
      >
        <IconChevronLeft size={18} />
      </button>
      <div className="cal-board" ref={ref} onScroll={sync}>
        {week.map((d, i) => (
          <DayColumn
            key={dayKey(d)}
            day={d}
            weekdayLabel={WEEKDAYS[i]}
            evts={cols[i]}
            today={dayKey(d) === todayKey}
            onPick={onPick}
          />
        ))}
      </div>
      <button
        type="button"
        className="cal-arrow r"
        title="后几天"
        disabled={!edge.right}
        onClick={() => page(1)}
      >
        <IconChevronRight size={18} />
      </button>
    </div>
  );
}

/* ============================================================
   本周 · 看板(参考 B 站放送表 https://www.bilibili.com/anime/timeline/)。

   ★ 抄的是它的**版式取舍**,不是像素。2026-07-16 直接读了 B 站自己的 bangumi-timeline.css:
       · .timeline-wrapper 固定 1120px、overflow:hidden;.season-timeline 每列 328px
         ⇒ 一屏并排**只放 3 天**,靠横向翻看整周。列宽而不是列多 —— 这是关键。
       · li.season-item:72×72 **方图** float:left + 右侧标题(12px,2 行截断)+ 灰色 desc。
       · 今天:.indicator 粉色条,今天 102px、其余 80px。
       · 响应式其实很糙:**只有一个断点** max-width:1400px,1120 → 980,两档而已。
   我们的差异(都是有理由的,不是抄漏):
       · 封面用 2:3 竖版 —— Bangumi 给的就是竖版海报,没有方图,硬裁成方的会切掉大半(踩过)。
       · 列宽用 clamp() + grid 自动列数 ⇒ **连续**跟着窗口变,比 B 站那两档更贴用户说的
         「随着页面的缩放去变化」。
   ★ 这里换掉了上一版「七天各一段时间线竖着摞」—— 那个一屏看不到几天,
     而看板一屏并排 3~4 天、每列自己滚,才是 PC 该有的密度。
   ============================================================ */
function DayColumn({
  day,
  weekdayLabel,
  evts,
  today,
  onPick,
}: {
  day: Date;
  weekdayLabel: string;
  evts: Evt[];
  today: boolean;
  onPick: (title: string) => void;
}) {
  const now = new Date();
  const nowMin = now.getHours() * 60 + now.getMinutes();
  const today0 = new Date(now);
  today0.setHours(0, 0, 0, 0);
  const dayCmp = Math.sign(day.getTime() - today0.getTime());

  return (
    <section className={`cal-bcol${today ? " today" : ""}`}>
      {/* 日期头 sticky:每列自己滚,不钉住滚两下就不知道这列是周几了(B 站也是 fixed 的)。 */}
      <div className="cal-bhd">
        <span className="cal-bwd">
          {weekdayLabel}
          {today && <b> · 今天</b>}
        </span>
        <span className="cal-bdate">
          {day.getMonth() + 1}-{day.getDate()}
        </span>
        {/* 今天的指示条更宽 + 用强调色 —— B 站那根粉条的作用,一眼定位今天。 */}
        <i className="cal-bbar" />
      </div>
      <div className="cal-bbody">
        {evts.length === 0 ? (
          <div className="cal-bempty">没有放送</div>
        ) : (
          evts.map((ev, i) => (
            <EvtCard
              key={`${ev.entry.title}-${i}`}
              evt={ev}
              st={statusOf(ev.time, nowMin, dayCmp)}
              // 用剧名而非「剧名 + 集号」去查:集号是放送表的信息,
              // 服务器上的条目名里未必带,带上反而搜不到。
              onClick={() => onPick(ev.entry.title)}
            />
          ))
        )}
      </div>
    </section>
  );
}

/* 简介缓存:模块级,跨组件重挂活着。
   悬停会被反复触发(鼠标在几档之间来回扫),每次重发请求就是「一扫就闪一下」。
   核层也有一层进程内缓存,这层省的是 IPC 往返。
   只增不删:条数上限就是放送表的番剧数(百量级),涨不爆。
   ★ 存 `null` 代表「查过了,确实没有」—— 不能用「键不存在」表示,否则没简介的那条
     每次展开都会再查一遍(反复打空)。 */
const summaryCache = new Map<number, string | null>();

/** 堆叠里的一张卡。折叠态:时刻 + 封面 + 名 + 评分。展开态:多给一段简介(地方够了才给)。 */
/** 日历的简介加载器。Trakt 内联就有;Bangumi 按需拉(见 CalendarEntry.summary)。 */
function CalSummary({ entry }: { entry: Evt["entry"] }) {
  const inline = entry.summary?.trim() || null;
  const bid = entry.bangumi_id;
  const [text, setText] = useState<string | null | undefined>(() =>
    inline ?? (bid != null ? summaryCache.get(bid) : null),
  );

  useEffect(() => {
    if (inline || bid == null) return; // Trakt 已内联 / 没有 id 可查
    if (summaryCache.has(bid)) {
      setText(summaryCache.get(bid));
      return;
    }
    let alive = true;
    setText(undefined); // undefined = 正在查(→ 骨架);null = 查过没有(→ 什么都不画)
    bangumiSummary(bid)
      .then((v) => {
        const t = v?.trim() || null;
        summaryCache.set(bid, t);
        if (alive) setText(t);
      })
      .catch(() => {
        // 拉不到简介不值得打扰用户(不 toast):锦上添花,不是功能坏了。
        // 但**不写缓存** —— 网络抖一下不该让这条永远没简介。
        if (alive) setText(null);
      });
    return () => {
      alive = false;
    };
  }, [inline, bid]);

  if (text === undefined) return <span className="cal-ssum skeleton" />;
  if (!text) return null; // 没有就不画 —— 不占位、更不编
  return <p className="cal-ssum">{text}</p>;
}

/** 看板里的一行(对位 B 站的 li.season-item:小封面 float 左 + 右侧标题 + 灰色 desc)。
    desc 放「时刻 · 状态」—— 这一列已经说了是周几,再重复日期没意义。 */
function EvtCard({ evt, st, onClick }: { evt: Evt; st: St; onClick: () => void }) {
  const { entry } = evt;
  const [loaded, setLoaded] = useState(false);
  return (
    <div
      className={`cal-brow${st === "past" ? " past" : ""}${st === "airing" ? " airing" : ""}`}
      onClick={onClick}
      title={`跨服查找可播源 · ${entry.title}`}
    >
      <div className="cal-bth">
        {entry.image_url && !loaded && <div className="cal-skel skeleton" />}
        {entry.image_url ? (
          <img
            className={`cal-bimg${loaded ? " ready" : ""}`}
            src={entry.image_url}
            alt={entry.title}
            loading="lazy"
            decoding="async"
            onLoad={() => setLoaded(true)}
            onError={(ev) => {
              setLoaded(true);
              (ev.target as HTMLImageElement).style.visibility = "hidden";
            }}
          />
        ) : (
          <span className="cal-bimg ph" />
        )}
      </div>
      <div className="cal-btxt">
        <span className="cal-bt1">{entry.title}</span>
        <span className="cal-bdesc">
          <b className="t">{evt.time ?? "待定"}</b>
          {st === "airing" && <em className="live">正在播出</em>}
          {entry.subtitle && <span className="sub">{entry.subtitle}</span>}
          {/* 评分:核层给的真字段。null = 没人评过 → 不画(画成 0.0 等于诽谤)。 */}
          {entry.rating != null && (
            <span className={`rate${entry.rating >= 8 ? " hi" : ""}`}>
              <i className="s">★</i>
              {entry.rating.toFixed(1)}
            </span>
          )}
        </span>
      </div>
    </div>
  );
}
