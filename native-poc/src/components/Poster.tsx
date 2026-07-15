import { type MouseEvent } from "react";
import { type Item, type LoginResult, itemLabel, posterUrl, thumbUrl } from "../lib/api";
import { IconPlay, IconLibrary } from "../app/icons";

type Props = {
  item: Item;
  session: LoginResult;
  variant?: "poster" | "thumb";
  /** 单击就走它 —— 卡片唯一的主操作。 */
  onOpen: (it: Item) => void;
  index?: number;
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
  index = 0,
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
        className={`pcard ${thumb ? "thumb-ar" : "poster-ar"} enter`}
        style={{ animationDelay: `${Math.min(index, 12) * 24}ms` }}
        /* 单击直接进详情:不再延后一拍等双击了 —— 没有双击,延迟只会让点击发粘。 */
        onClick={() => onOpen(item)}
        title={label}
      >
        {item.has_primary ? (
          <img
            src={src}
            loading="lazy"
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
