import {
  fmtRes,
  itemLabel,
  posterUrl,
  thumbUrl,
  type Item,
  type LoginResult,
} from "@shared/api";
import { FocusItem } from "./Focus";

/* 卡片。封面失败时露出底下的占位渐变(.th 自带),不画"加载失败"字样 ——
   一屏几十张卡,每张都写字反而比缺图更吵。 */

/** 16:9 横卡:继续观看 / 接下来看 / 分集。320x180dp。 */
export function CardWide({
  it,
  session,
  onEnter,
  showProgress,
}: {
  it: Item;
  session: LoginResult;
  onEnter?: () => void;
  showProgress?: boolean;
}) {
  const pct =
    showProgress && it.runtime_secs > 0
      ? Math.min(100, (it.resume_secs / it.runtime_secs) * 100)
      : 0;
  return (
    <FocusItem className="card169 fx" onEnter={onEnter}>
      <div className="th">
        {it.has_primary && <img src={thumbUrl(session, it.id, 640)} alt="" loading="lazy" />}
        {pct > 0 && (
          <div className="prog">
            <i style={{ width: `${pct}%` }} />
          </div>
        )}
      </div>
      <div className="nm">{itemLabel(it)}</div>
      <div className="sub">{wideSub(it)}</div>
    </FocusItem>
  );
}

/** 2:3 竖卡:媒体库 / 收藏 / 搜索结果网格。220x330dp。 */
export function CardPoster({
  it,
  session,
  onEnter,
}: {
  it: Item;
  session: LoginResult;
  onEnter?: () => void;
}) {
  return (
    <FocusItem className="card23 fx" onEnter={onEnter}>
      <div className="th">
        {it.has_primary && <img src={posterUrl(session, it.id, 480)} alt="" loading="lazy" />}
        {/* 未看集数角标。UserData.UnplayedItemCount 走的是 Item 上的字段,
            这里只在剧集上有意义。 */}
      </div>
      <div className="nm">{it.name}</div>
      <div className="sub">{[it.year, fmtRes(it.video_height)].filter(Boolean).join(" · ")}</div>
    </FocusItem>
  );
}

function wideSub(it: Item): string {
  const parts: string[] = [];
  if (it.season_no != null && it.episode_no != null)
    parts.push(`S${it.season_no} E${it.episode_no}`);
  if (it.runtime_secs > 0) parts.push(`${Math.round(it.runtime_secs / 60)} 分钟`);
  return parts.join(" · ");
}
