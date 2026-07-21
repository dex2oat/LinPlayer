/* 纵向滚动的位移计算。**独立成文件是为了能测** ——
   这段全是边界判断,而它算错的表现是「能滚,但差一截」:在电视上肉眼根本认不出来,
   只会被描述成「内容缺失」「回不到最顶」。放在 Focus.tsx 里就得连 React 一起 import,
   node 跑不起来,于是永远只能靠人在真机上瞪着看。 */

export type ScrollInput = {
  /** 焦点项相对可视区顶的位置(设备 px) */
  top: number;
  height: number;
  /** 焦点项所属「段」相对可视区顶的位置 */
  secTop: number;
  /** 该段是不是内容里的第一段 */
  firstSection: boolean;
  viewH: number;
  /** 顶部固定区高度(已乘过 zoom) */
  topPad: number;
  /** 焦点环呼吸位(已乘过 zoom) */
  pad: number;
};

/** 该滚多少(>0 = 内容要往上走,即焦点在下方)。0 = 不用动。
 *
 *  ★ 往上对齐的是**段顶**,不是焦点项自己。
 *    原来两个方向都只保证「焦点项露出来」,于是从下面的行往上回到 Hero,滚动停在
 *    「播放按钮顶端 + 呼吸位」—— 按钮上方那 400 多 px 的封面全在视野外。用户的原话是
 *    「从下往上一滑就缺失内容」:内容没丢,是滚过头了。行同理:停在卡片顶端会把行标题
 *    切在外面,整页看着像少了一截。
 *
 *  ★ 往下**不能**也按段顶/段底:段可能比整屏还高(Hero 486px),按段算会直接翻过头。 */
export function scrollDeltaY(a: ScrollInput): number {
  const lo = a.topPad + a.pad;
  if (a.top < lo) {
    // 第一段一路贴到真顶 —— 「无法回到最顶部」就是这里少减了段头那一截。
    return (a.firstSection ? a.secTop : Math.min(a.top, a.secTop)) - lo;
  }
  if (a.top + a.height > a.viewH - a.pad) return a.top + a.height - a.viewH + a.pad;
  return 0;
}
