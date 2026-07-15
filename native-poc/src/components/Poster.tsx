import { type MouseEvent } from "react";
import { type Item, type LoginResult, itemLabel, posterUrl, thumbUrl } from "../lib/api";
import { IconPlay, IconLibrary } from "../app/icons";

type Props = {
  item: Item;
  session: LoginResult;
  variant?: "poster" | "thumb";
  /** 单击就走它 —— 卡片唯一的主操作。 */
  onOpen: (it: Item) => void;
  /** 右键菜单。**只有首页传**(标记已/未播放、添加到喜欢);
      媒体库/收藏/搜索浮层不传 = 没有右键(保留浏览器默认)。 */
  onContextMenu?: (e: MouseEvent, it: Item) => void;
};

/* 海报卡:全端共用(首页轨道 / 媒体库网格 / 收藏网格 / 搜索浮层结果)。

   ★ 交互口径(2026-07-15 用户定,**覆盖草稿标注 7/11/36**):
     单击 = 进详情页;悬停 = 只浮起,**不出任何按钮**;双击**没有这一说**。
     播放与收藏一律回到详情页里做 —— 卡片是纯展示 + 一个入口。
   草稿画的悬停 ▶/♥ 与「双击进详情」已按此作废,别照草稿改回来。 */
export default function Poster({
  item,
  session,
  variant = "poster",
  onOpen,
  onContextMenu,
}: Props) {
  const thumb = variant === "thumb";
  const progress =
    !item.is_folder && item.resume_secs > 0 && item.runtime_secs > 0
      ? Math.min(100, (item.resume_secs / item.runtime_secs) * 100)
      : 0;
  const src = thumb ? thumbUrl(session, item.id) : posterUrl(session, item.id);
  const label = itemLabel(item);

  return (
    <div
      className="pitem"
      // 不传 onContextMenu 就不拦右键(保留浏览器默认菜单)。
      onContextMenu={onContextMenu ? (e) => onContextMenu(e, item) : undefined}
    >
      <div
        className={`pcard ${thumb ? "thumb-ar" : "poster-ar"}`}
        /* 单击直接进详情:不再延后一拍等双击了 —— 没有双击,延迟只会让点击发粘。 */
        onClick={() => onOpen(item)}
        title={label}
      >
        {item.has_primary ? (
          <img
            src={src}
            /* ★★ 这里曾是「不秒加载」的真凶,和缓存毫无关系。别把它们加回来。

               (1) `enter` + 按卡片下标算的 `animationDelay`(最多 288ms):
                   `.enter` = `animation: enter var(--dur-slow) both` = **380ms**,
                   而 `both` 意味着延迟期间元素**opacity:0 完全看不见**。
                   叠上最多 288ms 的阶梯延迟 → 一行里最后一张卡 **668ms** 才画完。
                   用户 2026-07-15:「切换回去之后还是不会秒加载 明明这些图片又不大」——
                   图早就在磁盘缓存里(实测 124 张/35.9MB),是 UI 自己在慢慢演。
                   **缓存再快也追不过一个写死 668ms 的动画。**

               (2) `loading="lazy"`:浏览器要等布局+相交检测才开始拉,首屏可见的卡
                   平白多等一轮。媒体库那种长列表值得 lazy,但那也该由列表自己决定,
                   不是每张卡都默认拖一下。改用 decoding="async" —— 解码不挡主线程,
                   但请求立刻发。

               入场动效不是不能有,但**不能挡着内容出现**。要加回动效请只动 transform,
               别动 opacity,更别用 fill-mode:both 把内容藏在延迟里。 */
            decoding="async"
            onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")}
          />
        ) : (
          <div className="fallback">
            {item.is_folder ? <IconLibrary size={30} /> : <IconPlay size={26} />}
          </div>
        )}
        {/* 评分角标(草稿标注 11)。核层 Item.rating 一直在传 —— 之前 .badge-tr 这条 CSS
            零调用方就是因为这里没渲染。
            「未看角标」需要 UserData.UnplayedItemCount,核层 Item 上没有这个字段 →
            不编,宁可缺角标也不显假数字。要补先给 Rust 的 emby::Item 加字段。 */}
        {item.rating != null && item.rating > 0 && (
          <div className="badge-tr" title={`评分 ${item.rating}`}>
            {item.rating.toFixed(1)}
          </div>
        )}
        {progress > 0 && (
          <div className="progress">
            <i style={{ width: `${progress}%` }} />
          </div>
        )}
      </div>
      <div className="pcap">{label}</div>
    </div>
  );
}
