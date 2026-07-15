import { useEffect, useRef, type MouseEvent } from "react";
import { type Item, type LoginResult, itemLabel, posterUrl, thumbUrl } from "../lib/api";
import { IconPlay, IconLibrary, IconHeart } from "../app/icons";

type Props = {
  item: Item;
  session: LoginResult;
  variant?: "poster" | "thumb";
  onOpen: (it: Item) => void;
  onPlay: (it: Item) => void;
  fav?: boolean;
  onToggleFav?: (it: Item) => void;
  index?: number;
  /** 右键菜单(草稿标注 11/36)。可选:不传就没有右键 —— 老调用方(首页/搜索浮层)行为不变。
      首页是自己在外层 div 上挂 onContextMenu 的,这里把能力收进卡片本体,新页面直接传就行。 */
  onContextMenu?: (e: MouseEvent, it: Item) => void;
};

/** 海报卡:草稿的悬停浮起 + 显现 ▶播放 / ♥收藏 + 进度条 + 评分角标。
    卡身单击=播放、双击=进详情(草稿标注 11/36:「双击 = 直接进详情」)。 */
export default function Poster({
  item,
  session,
  variant = "poster",
  onOpen,
  onPlay,
  fav,
  onToggleFav,
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

  /* 草稿标注 11/36 要「双击 = 进详情」。单击不能也进详情 —— 第一下就把页面换走了,
     双击永远触发不到。所以单击延后一拍,双击到了就撤销(手法同 DetailPage.epClick)。
     单击落「播放」:媒体卡的主操作就是播;文件夹播不了 → 退回进详情。 */
  const timer = useRef<number | null>(null);
  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );

  const click = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = window.setTimeout(() => {
      timer.current = null;
      if (item.is_folder) onOpen(item);
      else onPlay(item);
    }, 220);
  };
  const dblClick = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
    onOpen(item);
  };

  return (
    <div
      className="pitem"
      // 不传 onContextMenu 就不拦右键(保留浏览器默认),老调用方零影响。
      onContextMenu={onContextMenu ? (e) => onContextMenu(e, item) : undefined}
    >
      <div
        className={`pcard ${thumb ? "thumb-ar" : "poster-ar"} enter`}
        style={{ animationDelay: `${Math.min(index, 12) * 24}ms` }}
        onClick={click}
        onDoubleClick={dblClick}
        title={item.is_folder ? label : `${label}\n单击播放 · 双击进详情`}
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
        <div className="overlay">
          {onToggleFav ? (
            <button
              className={`ov-fav${fav ? " on" : ""}`}
              onClick={(e) => {
                e.stopPropagation();
                onToggleFav(item);
              }}
              title={fav ? "取消收藏" : "收藏"}
            >
              <IconHeart size={15} />
            </button>
          ) : (
            <span />
          )}
          {!item.is_folder && (
            <button
              className="ov-play"
              onClick={(e) => {
                e.stopPropagation();
                onPlay(item);
              }}
              title="播放"
            >
              <IconPlay size={16} />
            </button>
          )}
        </div>
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
