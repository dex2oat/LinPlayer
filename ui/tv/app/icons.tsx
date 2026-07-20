/* ============================================================
   TV 图标 sprite —— 全站唯一一套 24 视野 stroke 线性图标。

   ★ 本文件由 scripts 从 docs/tv-drafts.html 的 <symbol> 原样搬运,不是重画的。
     草稿评审时逐个确认过"这个按钮是干嘛的",重画一遍等于把那轮评审作废。
     改图标 → 先改草稿,再搬过来。

   用法:<TvIconSprite/> 挂一次在根,各处 <Icon n="play"/> 引用。
   ============================================================ */

/** 图标名。加新图标要先进草稿的 sprite。 */
export type IconName =
  | "search"
  | "home"
  | "library"
  | "heart"
  | "compass"
  | "download"
  | "server"
  | "settings"
  | "play"
  | "pause"
  | "prev"
  | "next"
  | "rew"
  | "fwd"
  | "sub"
  | "audio"
  | "danmaku"
  | "more"
  | "back"
  | "check"
  | "plus"
  | "skip"
  | "lock"
  | "cast"
  | "shot"
  | "refresh"
  | "trash"
  | "edit"
  | "qr"
  | "folder"
  | "file"
  | "up"
  | "filter"
  | "warn"
  | "info"
  | "timer";

/** 单个图标。size 走 className(.ic / .ic-rail / .ic-btn / .ic-c / .ic-lg),
 *  颜色一律 currentColor —— 焦点态换字色,图标自动跟上。 */
export function Icon({ n, className = "ic" }: { n: IconName; className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden>
      <use href={`#i-${n}`} />
    </svg>
  );
}

/** sprite 定义。整个应用挂一次,放在 .tv-app 内的任何位置都行。 */
export function TvIconSprite() {
  return (
    <svg width="0" height="0" style={{ position: "absolute" }} aria-hidden>
      <defs>
        <symbol id="i-search" viewBox="0 0 24 24">
          <circle cx="11" cy="11" r="7"/><path d="M16.5 16.5 21 21"/>
        </symbol>
        <symbol id="i-home" viewBox="0 0 24 24">
          <path d="M3 11l9-7 9 7v8a2 2 0 0 1-2 2h-4v-6H9v6H5a2 2 0 0 1-2-2z"/>
        </symbol>
        <symbol id="i-library" viewBox="0 0 24 24">
          <rect x="3" y="4" width="7" height="16" rx="1"/><rect x="14" y="4" width="7" height="7" rx="1"/><rect x="14" y="13" width="7" height="7" rx="1"/>
        </symbol>
        <symbol id="i-heart" viewBox="0 0 24 24">
          <path d="M12 20.5S3.5 15.4 3.5 9.6C3.5 6.9 5.6 5 8 5c1.7 0 3.1 1 4 2.2C12.9 6 14.3 5 16 5c2.4 0 4.5 1.9 4.5 4.6 0 5.8-8.5 10.9-8.5 10.9z"/>
        </symbol>
        <symbol id="i-compass" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="9"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>
        </symbol>
        <symbol id="i-download" viewBox="0 0 24 24">
          <path d="M12 3v12"/><path d="M8 11l4 4 4-4"/><path d="M4 19h16"/>
        </symbol>
        <symbol id="i-server" viewBox="0 0 24 24">
          <rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>
        </symbol>
        <symbol id="i-settings" viewBox="0 0 24 24">
          <path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2.4"/><circle cx="8" cy="17" r="2.4"/>
        </symbol>
        <symbol id="i-play" viewBox="0 0 24 24">
          <path d="M7 4.5v15l13-7.5z" fill="currentColor" stroke="none"/>
        </symbol>
        <symbol id="i-pause" viewBox="0 0 24 24">
          <rect x="6" y="4.5" width="4" height="15" rx="1" fill="currentColor" stroke="none"/><rect x="14" y="4.5" width="4" height="15" rx="1" fill="currentColor" stroke="none"/>
        </symbol>
        <symbol id="i-prev" viewBox="0 0 24 24">
          <rect x="4" y="5" width="2.6" height="14" rx="1" fill="currentColor" stroke="none"/><path d="M20 5v14l-11-7z" fill="currentColor" stroke="none"/>
        </symbol>
        <symbol id="i-next" viewBox="0 0 24 24">
          <rect x="17.4" y="5" width="2.6" height="14" rx="1" fill="currentColor" stroke="none"/><path d="M4 5v14l11-7z" fill="currentColor" stroke="none"/>
        </symbol>
        <symbol id="i-rew" viewBox="0 0 24 24">
          <path d="M11 4.5A7.5 7.5 0 1 1 4 12"/><path d="M4 4.5V9h4.5"/><text x="12" y="15.5" fontSize="8" textAnchor="middle" fill="currentColor" stroke="none" fontFamily="sans-serif">10</text>
        </symbol>
        <symbol id="i-fwd" viewBox="0 0 24 24">
          <path d="M13 4.5A7.5 7.5 0 1 0 20 12"/><path d="M20 4.5V9h-4.5"/><text x="12" y="15.5" fontSize="8" textAnchor="middle" fill="currentColor" stroke="none" fontFamily="sans-serif">10</text>
        </symbol>
        <symbol id="i-sub" viewBox="0 0 24 24">
          <rect x="3" y="5" width="18" height="14" rx="2"/><path d="M6.5 14h5M14 14h3.5"/>
        </symbol>
        <symbol id="i-audio" viewBox="0 0 24 24">
          <path d="M4 9.5h3.5L12 5.5v13L7.5 14.5H4z"/><path d="M16 9.5a4 4 0 0 1 0 5"/><path d="M18.6 7a7.5 7.5 0 0 1 0 10"/>
        </symbol>
        <symbol id="i-danmaku" viewBox="0 0 24 24">
          <rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21l3-4"/><path d="M6.5 9.5h6M6.5 12.8h4M15 9.5h2.5"/>
        </symbol>
        <symbol id="i-more" viewBox="0 0 24 24">
          <circle cx="5.5" cy="12" r="1.7" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none"/><circle cx="18.5" cy="12" r="1.7" fill="currentColor" stroke="none"/>
        </symbol>
        <symbol id="i-back" viewBox="0 0 24 24">
          <path d="M15 5l-7 7 7 7"/>
        </symbol>
        <symbol id="i-check" viewBox="0 0 24 24">
          <path d="M4.5 12.5l5 5L20 7"/>
        </symbol>
        <symbol id="i-plus" viewBox="0 0 24 24">
          <path d="M12 5v14M5 12h14"/>
        </symbol>
        <symbol id="i-skip" viewBox="0 0 24 24">
          <path d="M5 5v14l9-7z" fill="currentColor" stroke="none"/><path d="M17 5v14"/>
        </symbol>
        <symbol id="i-lock" viewBox="0 0 24 24">
          <rect x="4.5" y="10.5" width="15" height="9.5" rx="2"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>
        </symbol>
        <symbol id="i-cast" viewBox="0 0 24 24">
          <path d="M3 18.5h.01"/><path d="M3 14.5a5 5 0 0 1 5 5"/><path d="M3 10.5a9 9 0 0 1 9 9"/><path d="M3 8V6a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3"/>
        </symbol>
        <symbol id="i-shot" viewBox="0 0 24 24">
          <rect x="3" y="7" width="18" height="13" rx="2"/><circle cx="12" cy="13.5" r="3.6"/><path d="M8.5 7l1.4-2.5h4.2L15.5 7"/>
        </symbol>
        <symbol id="i-refresh" viewBox="0 0 24 24">
          <path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v5h-5"/>
        </symbol>
        <symbol id="i-trash" viewBox="0 0 24 24">
          <path d="M4 7h16"/><path d="M9.5 7V4.5h5V7"/><path d="M6.5 7l1 12.5h9L17.5 7"/>
        </symbol>
        <symbol id="i-edit" viewBox="0 0 24 24">
          <path d="M4 20h4L19.5 8.5a2.1 2.1 0 0 0-3-3L5 17z"/><path d="M14.5 6.5l3 3"/>
        </symbol>
        <symbol id="i-qr" viewBox="0 0 24 24">
          <rect x="3.5" y="3.5" width="7" height="7" rx="1"/><rect x="13.5" y="3.5" width="7" height="7" rx="1"/><rect x="3.5" y="13.5" width="7" height="7" rx="1"/><path d="M13.5 13.5h3v3h-3zM19 19h1.5v1.5H19z"/>
        </symbol>
        <symbol id="i-folder" viewBox="0 0 24 24">
          <path d="M3 6.5a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>
        </symbol>
        <symbol id="i-file" viewBox="0 0 24 24">
          <path d="M6 3.5h8l4.5 4.5V20a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 20V5A1.5 1.5 0 0 1 6 3.5z"/><path d="M13.5 3.5V9h5"/>
        </symbol>
        <symbol id="i-up" viewBox="0 0 24 24">
          <path d="M12 19V6"/><path d="M6 12l6-6 6 6"/>
        </symbol>
        <symbol id="i-filter" viewBox="0 0 24 24">
          <path d="M4 6h16M7 12h10M10 18h4"/>
        </symbol>
        <symbol id="i-warn" viewBox="0 0 24 24">
          <path d="M12 4.5l8.5 15h-17z"/><path d="M12 10v4M12 17h.01"/>
        </symbol>
        <symbol id="i-info" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.8h.01"/>
        </symbol>
        <symbol id="i-timer" viewBox="0 0 24 24">
          <circle cx="12" cy="13.5" r="7.5"/><path d="M12 9.5v4l2.5 2"/><path d="M9.5 2.5h5"/>
        </symbol>
      </defs>
    </svg>
  );
}
