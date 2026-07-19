/* 收藏排序自检。跑法:
     cd native-poc && npx tsx src/pages/favorites-sort.test.mjs
   (或 node --experimental-strip-types src/pages/favorites-sort.test.mjs)
   反向验证过:把 sortItems 里的 `return asc ? d : -d` 改成 `return d`,本测试立刻红。 */
import assert from "node:assert/strict";
import { sortItems } from "./favorites-sort.ts";

const it = (name, rating, date, sortName = null) => ({
  name, rating, date_updated: date, sort_name: sortName,
});

const data = [
  it("钟馗", 3.5, "2026-07-07T09:24:40+08:00"),
  it("爱情有烟火", 10, "2026-06-20T07:01:26+08:00"),
  it("我成为了贵族", null, null),
  it("虽然我是不完美恶女", 8, "2026-07-13T08:20:57+08:00"),
];
const names = (x) => x.map((i) => i.name);

// 评分:升序低分在前,降序高分在前,无评分永远沉底。
assert.deepEqual(names(sortItems(data, "rating", true)), ["钟馗", "虽然我是不完美恶女", "爱情有烟火", "我成为了贵族"]);
assert.deepEqual(names(sortItems(data, "rating", false)), ["爱情有烟火", "虽然我是不完美恶女", "钟馗", "我成为了贵族"]);

// 更新时间:降序最新在前。
assert.deepEqual(names(sortItems(data, "updated", false)).slice(0, 3), ["虽然我是不完美恶女", "钟馗", "爱情有烟火"]);
assert.deepEqual(names(sortItems(data, "updated", true)).slice(0, 3), ["爱情有烟火", "钟馗", "虽然我是不完美恶女"]);

// 名称:升降序必须互为逆序(这条就是「点了升降序不变」那个 bug 的守门人)。
const asc = names(sortItems(data, "name", true));
const desc = names(sortItems(data, "name", false));
assert.deepEqual(desc, [...asc].reverse(), "名称升序和降序必须互为逆序");

// sort_name 优先于 name。
const withSortName = [it("B片", 1, null, "A"), it("A片", 1, null, "B")];
assert.deepEqual(names(sortItems(withSortName, "name", true)), ["B片", "A片"]);

// 不能就地改原数组(items 是 React state)。
const before = names(data);
sortItems(data, "rating", false);
assert.deepEqual(names(data), before, "sortItems 不能改动入参");

console.log("favorites-sort: 全部通过");
