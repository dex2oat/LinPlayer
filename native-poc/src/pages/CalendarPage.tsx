import { useCallback, useEffect, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  type CalendarEntry,
  afdianVerify,
  bangumiCalendar,
  traktCalendar,
} from "../lib/api";
import { IconChevronLeft, IconChevronRight } from "../app/icons";
import { SourcePicker } from "./RankingsPage";
import "./CalendarPage.css";

type Props = { onBack: () => void };
type Source = "trakt" | "bangumi";

const WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
// 软锁:存校验通过的订单号即视为已解锁,不每次联网重校(爱发电校验要网络)。
const LOCK_KEY = "cal:afdian";
/** 赞助下单页。爱发电校验走 afdianVerify(订单号),这里只负责把人送到下单页。 */
const kAfdianSponsorUrl = "https://afdian.com/a/linplayer";

/** 周一为一周首日:getDay() 0=周日 → 挪到末位。 */
function mondayOf(base: Date, weekOffset: number): Date {
  const d = new Date(base);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7) + weekOffset * 7);
  return d;
}

/** 本地日历日的稳定 key —— 不能用 toISOString(那是 UTC,会把深夜番挪错一天)。 */
const dayKey = (d: Date) =>
  `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;

const hhmm = (d: Date) =>
  `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

type Evt = { entry: CalendarEntry; time: string | null };

/** 归组是前端的活:air_date 落真实日期,只有 weekday 的落当前周对应列,都没有的丢弃。 */
function groupByDay(entries: CalendarEntry[], week: Date[]): Evt[][] {
  const cols: Evt[][] = week.map(() => []);
  const keys = week.map(dayKey);
  for (const e of entries) {
    if (e.air_date) {
      const d = new Date(e.air_date);
      if (Number.isNaN(d.getTime())) continue;
      const i = keys.indexOf(dayKey(d));
      if (i >= 0) cols[i].push({ entry: e, time: hhmm(d) });
    } else if (e.weekday != null && e.weekday >= 1 && e.weekday <= 7) {
      // 没有精确时刻 → 不编造播出时间。
      cols[e.weekday - 1].push({ entry: e, time: null });
    }
  }
  // 同一天按时间升序;无时刻的沉到末尾。
  for (const c of cols) {
    c.sort((a, b) => (a.time ?? "￿").localeCompare(b.time ?? "￿"));
  }
  return cols;
}

export default function CalendarPage({ onBack }: Props) {
  const [unlocked, setUnlocked] = useState(
    () => !!localStorage.getItem(LOCK_KEY),
  );
  const [source, setSource] = useState<Source>("trakt");
  const [onlyMine, setOnlyMine] = useState(true);
  const [weekOffset, setWeekOffset] = useState(0);
  const [entries, setEntries] = useState<CalendarEntry[] | null>(null);
  const [toast, setToast] = useState<{ msg: string; error?: boolean } | null>(
    null,
  );
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
          source === "trakt"
            ? await traktCalendar(onlyMine)
            : await bangumiCalendar(onlyMine);
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

  const week = Array.from({ length: 7 }, (_, i) => {
    const d = mondayOf(new Date(), weekOffset);
    d.setDate(d.getDate() + i);
    return d;
  });
  const todayKey = dayKey(new Date());
  const cols = groupByDay(entries ?? [], week);
  const total = cols.reduce((n, c) => n + c.length, 0);
  const weekLabel =
    weekOffset === 0
      ? "本周"
      : `${week[0].getMonth() + 1}月${week[0].getDate()}日 – ${week[6].getMonth() + 1}月${week[6].getDate()}日`;

  return (
    <>
      <div className="cbar">
        <button type="button" className="ibtn" title="返回" onClick={onBack}>
          <IconChevronLeft size={15} />
        </button>
        <span className="crumb">
          <b>追剧日历</b>
          {unlocked && <span className="cal-lock-tag">· 已解锁</span>}
        </span>
        {unlocked && (
          <span className="push">
            <span className="seg">
              <span
                className={source === "trakt" ? "on" : undefined}
                onClick={() => setSource("trakt")}
              >
                Trakt
              </span>
              <span
                className={source === "bangumi" ? "on" : undefined}
                onClick={() => setSource("bangumi")}
              >
                Bangumi
              </span>
            </span>
            <span className="pill" onClick={() => setOnlyMine((v) => !v)}>
              只看我追的
              <span className={onlyMine ? "sw on" : "sw"}>
                <i />
              </span>
            </span>
            <button
              type="button"
              className="ibtn"
              title="上一周"
              onClick={() => setWeekOffset((w) => w - 1)}
            >
              <IconChevronLeft size={15} />
            </button>
            <span
              className="pill"
              title="回到本周"
              onClick={() => setWeekOffset(0)}
            >
              {weekLabel}
            </span>
            <button
              type="button"
              className="ibtn"
              title="下一周"
              onClick={() => setWeekOffset((w) => w + 1)}
            >
              <IconChevronRight size={15} />
            </button>
          </span>
        )}
      </div>

      <div className="scroll">
        <div className="cbody">
          {!unlocked ? (
            <div className="cal-gate">
              <div className="cal-gate-h">追剧日历 · 赞助解锁</div>
              <div className="cal-gate-p">
                这是付费功能。在爱发电赞助后，用订单号解锁本机。
              </div>
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
                    openUrl(kAfdianSponsorUrl).catch((e) =>
                      say(`打不开浏览器：${e}。请手动访问 ${kAfdianSponsorUrl}`, true),
                    )
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
                  本周没有放送，或尚未登录该账号 —— 可在 设置 › Trakt / Bangumi
                  登录。
                </div>
              )}
              <div className="cal-weekgrid">
                {week.map((d, i) => {
                  const today = dayKey(d) === todayKey;
                  return (
                    <div
                      className={today ? "cal-daycol today" : "cal-daycol"}
                      key={dayKey(d)}
                    >
                      <div className={today ? "cal-dayhd today" : "cal-dayhd"}>
                        <span className="cal-wd">
                          {WEEKDAYS[i]}
                          {today ? " · 今天" : ""}
                        </span>
                        <div className="cal-d">{d.getDate()}</div>
                      </div>
                      <div className="cal-dbody">
                        {cols[i].map((ev, j) => (
                          <EvtCard
                            key={`${ev.entry.title}-${j}`}
                            evt={ev}
                            // 用剧名而非「剧名 + 集号」去查:集号是放送表的信息,
                            // 服务器上的条目名里未必带,带上反而搜不到。
                            onClick={() => setPick(ev.entry.title)}
                          />
                        ))}
                      </div>
                    </div>
                  );
                })}
              </div>
            </>
          )}
        </div>
      </div>

      {pick && <SourcePicker title={pick} onClose={() => setPick(null)} />}

      {toast && (
        <div className={toast.error ? "toast error" : "toast"}>{toast.msg}</div>
      )}
    </>
  );
}

function EvtCard({ evt, onClick }: { evt: Evt; onClick: () => void }) {
  const { entry, time } = evt;
  const name = entry.subtitle ? `${entry.title} ${entry.subtitle}` : entry.title;
  return (
    <div className="cal-evt" title={name} onClick={onClick}>
      {entry.image_url ? (
        <img
          className="cal-th"
          src={entry.image_url}
          alt={name}
          loading="lazy"
          onError={(ev) =>
            ((ev.target as HTMLImageElement).style.visibility = "hidden")
          }
        />
      ) : (
        <span className="ph cal-th" />
      )}
      <div className="cal-in">
        <span className="cal-t1">{name}</span>
        {time && <span className="cal-t2">{time}</span>}
      </div>
    </div>
  );
}
