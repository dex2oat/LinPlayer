/* 追剧日历的纯逻辑(归组 / 焦点定位 / 播出状态 / 滚轮步进)—— 不碰 React / DOM / Tauri。
   单独成模块是为了能被 scripts/check-calendar-grouping.mjs **直接跑真代码**验证:
   2026-07-16 这里出过一个把整页打黑屏的越界 bug(见 groupByWeek 注释),
   而它本来一个断言就能挡住。放在 .tsx 里就只能靠抄一份副本去"测",那种测试测的不是这份代码。 */

import type { CalendarEntry } from "@shared/api";

export type Evt = { entry: CalendarEntry; time: string | null };

/** 周一为一周首日:getDay() 0=周日 → 挪到末位。 */
export function mondayOf(base: Date, weekOffset: number): Date {
  const d = new Date(base);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7) + weekOffset * 7);
  return d;
}

/** 本地日历日的稳定 key —— 不能用 toISOString(那是 UTC,会把深夜番挪错一天)。 */
export const dayKey = (d: Date) => `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;

export const hhmm = (d: Date) =>
  `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

/** 一周七天(周一起)。week[i] 的 i 就是 weekday-1,groupByWeek 的列序全靠这个口径。 */
export function weekOf(base: Date, weekOffset: number): Date[] {
  return Array.from({ length: 7 }, (_, i) => {
    const d = mondayOf(base, weekOffset);
    d.setDate(d.getDate() + i);
    return d;
  });
}

/** theDay 在 weekOf() 结果里的列下标(周一=0)。 */
export const weekdayIndex = (d: Date) => (d.getDay() + 6) % 7;

/** "23:30" → 1410。只收 groupByWeek 产出的 hhmm 格式,不做通用解析。 */
export const hm2min = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));

/** 「正在播出」的窗口:开播后多少分钟内仍算在播。
 *  ★ 这是**启发式**,不是真相:放送表只给开播时刻,不给单集时长。
 *  番剧单集普遍 24 分钟(含 OP/ED),30 分钟是台标准时段 —— 取 30 是个诚实的近似,
 *  别把它当成「核层查到的真实播出状态」。 */
export const AIRING_WINDOW_MIN = 30;

/** 归组是前端的活:air_date 落真实日期,只有 weekday 的落当前周对应列,都没有的丢弃。
 *
 *  ★★ `week` **必须是整周 7 天(周一起)**,不是「随便几天都行」:
 *  下面 weekday 分支是 `cols[e.weekday - 1]` —— 按**绝对星期几**索引,写死了 7 列。
 *  2026-07-16 我为了做「本日」视图把单天数组 `[theDay]` 喂了进来,cols 长度成了 1,
 *  于是 weekday≥2 的条目全都 `cols[undefined].push` → 抛错 → React 整棵树卸载 →
 *  Tauri 窗口是透明的,露出底下的 mpv = **整页黑屏,页面打都打不开**。
 *  要「某一天」的条目,拿它所在**整周**跑一遍再取那一列(见 CalendarPage 的 dayEvts)。
 */
export function groupByWeek(entries: CalendarEntry[], week: Date[]): Evt[][] {
  // 契约靠断言钉死,不靠注释被读到:传错长度就当场炸在这儿,而不是几十行外 undefined.push。
  if (week.length !== 7) throw new Error(`groupByWeek 需要整周 7 天,收到 ${week.length}`);
  const cols: Evt[][] = week.map(() => []);
  const keys = week.map(dayKey);
  for (const e of entries) {
    if (e.air_date) {
      const d = new Date(e.air_date);
      if (Number.isNaN(d.getTime())) continue;
      const i = keys.indexOf(dayKey(d));
      if (i >= 0) cols[i].push({ entry: e, time: hhmm(d) });
    } else if (e.weekday != null && e.weekday >= 1 && e.weekday <= 7) {
      /* Bangumi 归组用 weekday。放送时刻:官方 API 没有(实测 /calendar 与 subject infobox
         都不含 hh:mm),核层用 bangumi-data 的 broadcast 补上首播时刻(按周重复 → 时分即每周更新
         时间),这里换算成**本地**时分显示。取不到就 null —— 不编造播出时间。 */
      const b = e.broadcast_at ? new Date(e.broadcast_at) : null;
      const time = b && !Number.isNaN(b.getTime()) ? hhmm(b) : null;
      cols[e.weekday - 1].push({ entry: e, time });
    }
  }
  // 同一天按时间升序;无时刻的沉到末尾。
  for (const c of cols) {
    c.sort((a, b) => (a.time ?? "￿").localeCompare(b.time ?? "￿"));
  }
  return cols;
}

/** 一条放送的播出状态。 */
export type St = "airing" | "past" | "soon";

/** 某条的播出状态。dayCmp:-1 昨天以前 / 0 今天 / 1 明天以后。
 *  ★「正在播出」是**估的**(放送表只给开播时刻,没有单集时长),见 AIRING_WINDOW_MIN。 */
export function statusOf(time: string | null, nowMin: number, dayCmp: number): St {
  if (dayCmp < 0) return "past"; // 过去的日子:整天都播完了
  if (dayCmp > 0) return "soon"; // 未来的日子:整天都还没播
  if (!time) return "soon"; // 今天但时刻未知 —— 不能凭空说它播完了
  const m = hm2min(time);
  if (m > nowMin) return "soon";
  return nowMin - m < AIRING_WINDOW_MIN ? "airing" : "past";
}



