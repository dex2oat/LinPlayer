/* 纵向滚动位移自检。跑法:
     npx tsx ui/tv/app/scroll.test.mjs
   反向验证过(见文件末尾那段注释里的两处改动),两条关键断言都能红。 */
import assert from "node:assert/strict";
import { scrollDeltaY } from "./scroll.ts";

/* 真机数量级:1080 高的可视区,呼吸位 32,无顶部固定区。 */
const base = { viewH: 1080, topPad: 0, pad: 32 };

/* ---- 1. 从下面的行往上回到 Hero ----
   Hero 高 486,焦点是它底部的「播放」按钮(段顶上方 380px 处)。
   焦点项自己已经在视野里偏上(top=-380 表示按钮被顶出去了一点),
   段顶在 -760。正确行为:按**段顶**算,把整张封面拉回来。 */
{
  const d = scrollDeltaY({ ...base, top: -380, height: 64, secTop: -760, firstSection: true });
  assert.equal(d, -792, "回 Hero 时必须按段顶(-760-32)算,否则封面上半截永远看不到");
}

/* ---- 2. 「无法回到最顶部」----
   第一段整体只差一点点没露全(段顶 -10),焦点项在段内靠下(top=20,已在 lo 之下)。
   必须把段顶拉到 +32(呼吸位),即 delta = -10-32 = -42。 */
{
  const d = scrollDeltaY({ ...base, top: 20, height: 64, secTop: -10, firstSection: true });
  assert.equal(d, -42, "第一段要贴到真顶,不能停在焦点项自己的位置");
}

/* ---- 3. 非第一段:取焦点项和段顶里更靠上的那个 ----
   一行的标题在卡片上方 60px。焦点落到卡片(top=10)时,行标题在 -50,必须一起带出来。 */
{
  const d = scrollDeltaY({ ...base, top: 10, height: 300, secTop: -50, firstSection: false });
  assert.equal(d, -82, "行标题(段顶)必须跟着焦点一起进视野");
}

/* ---- 4. 往下:只按焦点项的底,绝不按段 ----
   段很高(secTop=-2000,比如整块媒体信息),焦点项在屏幕底部外面一点。
   只该滚出焦点项需要的那点距离,按段算会直接翻过头。 */
{
  const d = scrollDeltaY({ ...base, top: 1000, height: 200, secTop: -2000, firstSection: false });
  assert.equal(d, 152, "往下必须按焦点项底算(1000+200-1080+32),按段会翻过头");
}

/* ---- 5. 已经在舒适区里就不要动 ----
   任何多余的位移都会让画面无意义地抖一下。 */
{
  const d = scrollDeltaY({ ...base, top: 400, height: 200, secTop: 380, firstSection: false });
  assert.equal(d, 0, "焦点已在视野中央,不该产生位移");
}

/* ---- 6. topPad(页标题不跟着滚)要计入上界 ---- */
{
  const d = scrollDeltaY({ top: 50, height: 64, secTop: 50, firstSection: false, viewH: 1080, topPad: 120, pad: 32 });
  assert.equal(d, -102, "有固定页头时,上界是 topPad+pad 而不是 pad");
}

console.log("scroll: 6 条全过");

/* 反向验证记录(2026-07-21 实跑):
     · 把 `a.firstSection ? a.secTop : Math.min(a.top, a.secTop)` 改回 `a.top`
       → 第 1/2/3 条同时红(-412 ≠ -792 等),正是修好前的行为;
     · 把往下那条改成按 secTop 算
       → 第 4 条红(-2000+…),即「往下翻过头」。 */
