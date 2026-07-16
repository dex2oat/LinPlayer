/* 追剧日历归组逻辑的自检。跑法:
 *     node scripts/check-calendar-grouping.mjs
 *
 * ★ 它 import 的是 **src/pages/calendar-grouping.ts 本尊**(Node 24 原生剥类型),
 *   不是抄一份副本进来测 —— 副本测的是副本,永远绿。本仓已经栽过两次。
 *
 * 由来:2026-07-16「切到追剧日历直接黑屏,打都打不开」。真因是日视图给 groupByWeek
 * 喂了个只有 1 天的数组,而它的 weekday 分支按绝对星期几索引 7 列 → cols[undefined].push
 * 抛错 → React 整棵树卸载 → 透明窗口露出 mpv = 黑屏。
 */
import assert from "node:assert/strict";
import {
  groupByWeek,
  statusOf,
  weekOf,
  weekdayIndex,
} from "../src/pages/calendar-grouping.ts";

const mk = (title, weekday, broadcast_at = null) => ({
  title,
  subtitle: null,
  weekday,
  air_date: null,
  broadcast_at,
  image_url: null,
});

let n = 0;
const ok = (name, fn) => {
  fn();
  n++;
  console.log(`  ok  ${name}`);
};

// 2026-07-15 是周三(周一=0 → 下标 2)。钉死日期,别用 new Date() —— 那样测试会随今天是周几而飘。
const WED = new Date(2026, 6, 15);

ok("整周七天:每个 weekday 落进对应列", () => {
  const cols = groupByWeek(
    Array.from({ length: 7 }, (_, i) => mk(`番${i + 1}`, i + 1)),
    weekOf(WED, 0),
  );
  assert.equal(cols.length, 7);
  for (let i = 0; i < 7; i++) {
    assert.equal(cols[i].length, 1, `第 ${i} 列该有 1 部`);
    assert.equal(cols[i][0].entry.title, `番${i + 1}`);
  }
});

ok("★ 黑屏那颗雷:短数组必须当场抛错,不能越界写 undefined", () => {
  // 修好之前,这一行不是抛「需要整周 7 天」,而是抛 TypeError: Cannot read properties of
  // undefined (reading 'push') —— 从 CalendarPage 渲染里冒出去,整页黑。
  assert.throws(() => groupByWeek([mk("番", 3)], [WED]), /需要整周 7 天,收到 1/);
});

ok("日视图取列口径:weekdayIndex 指向的正是该 weekday 的那一列", () => {
  const cols = groupByWeek([mk("周三番", 3), mk("周日番", 7)], weekOf(WED, 0));
  assert.equal(weekdayIndex(WED), 2); // 周三
  assert.deepEqual(cols[weekdayIndex(WED)].map((e) => e.entry.title), ["周三番"]);
  const sun = new Date(2026, 6, 19);
  assert.equal(weekdayIndex(sun), 6);
  assert.deepEqual(cols[weekdayIndex(sun)].map((e) => e.entry.title), ["周日番"]);
});

ok("同一天按时刻升序,无时刻的沉到末尾(不编造时间)", () => {
  const cols = groupByWeek(
    [
      mk("没时刻的", 3),
      mk("23点的", 3, new Date(2026, 6, 15, 23, 30).toISOString()),
      mk("1点的", 3, new Date(2026, 6, 15, 1, 5).toISOString()),
    ],
    weekOf(WED, 0),
  );
  assert.deepEqual(cols[2].map((e) => e.entry.title), ["1点的", "23点的", "没时刻的"]);
  assert.equal(cols[2][2].time, null); // 取不到就是 null,不是 "00:00"
});

ok("weekOf 恒返回 7 天且以周一起", () => {
  for (const off of [-1, 0, 1]) {
    const w = weekOf(WED, off);
    assert.equal(w.length, 7);
    assert.equal(w[0].getDay(), 1); // 周一
    assert.equal(w[6].getDay(), 0); // 周日
  }
});

/* ---------- 播出状态 ---------- */
const at = (hh, mm = 0) => hh * 60 + mm; // 便于把 "23:30" 写成 at(23,30)
/** 造一天的放送(时间升序,和 groupByWeek 的产出口径一致)。 */
const evt = (time) => ({ entry: { title: time ?? "待定" }, time });

ok("状态:今天 = 正在播 / 已播 / 待播 三态各就各位", () => {
  assert.equal(statusOf("23:00", at(23, 10), 0), "airing"); // 开播 10 分钟,窗口内
  assert.equal(statusOf("23:00", at(23, 29), 0), "airing"); // 29 分钟,边界内
  assert.equal(statusOf("23:00", at(23, 30), 0), "past"); // 30 分钟,窗口外 = 已播
  assert.equal(statusOf("23:00", at(22, 59), 0), "soon"); // 还没到
});

ok("状态:过去的日子整天已播,未来的日子整天待播", () => {
  assert.equal(statusOf("23:00", at(1), -1), "past");
  assert.equal(statusOf("01:00", at(23), 1), "soon");
});

ok("状态:今天但时刻未知 → 待播,不能凭空说它播完了", () => {
  assert.equal(statusOf(null, at(23, 59), 0), "soon");
});

console.log(`\n全部 ${n} 项通过。`);
