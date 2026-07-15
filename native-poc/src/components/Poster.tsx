import type { MouseEvent } from "react";
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

/** 海报卡:草稿的悬停浮起 + 显现 ▶播放 / ♥收藏 + 进度条。卡身点击=进详情。 */
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

  return (
    <div
      className="pitem"
      // 不传 onContextMenu 就不拦右键(保留浏览器默认),老调用方零影响。
      onContextMenu={onContextMenu ? (e) => onContextMenu(e, item) : undefined}
    >
      <div
        className={`pcard ${thumb ? "thumb-ar" : "poster-ar"} enter`}
        style={{ animationDelay: `${Math.min(index, 12) * 24}ms` }}
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
