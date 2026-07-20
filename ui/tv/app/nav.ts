import type { IconName } from "./icons";

/** 路由 id。detail / episode / player / addserver / lines 是内部路由,不进导航轨。 */
export type PageId =
  | "search"
  | "home"
  | "library"
  | "favorites"
  | "discover"
  | "downloads"
  | "servers"
  | "settings"
  /* --- 以下不进导航轨 --- */
  | "detail"
  | "episode"
  | "player"
  | "addserver"
  | "lines"
  | "netdisk";

export type NavItem = { id: PageId; label: string; icon: IconName };

/** 导航轨主区。
 *  ★ 与 PC 侧栏的差异是**故意**的:PC 的「排行榜」和「追剧日历」在 TV 上合成一个
 *    「发现」入口 —— 遥控器的代价是焦点格数,轨上每多一项,所有下方项都远一格。
 *    两者都是"我不知道看什么"时才进的页,合并后在页内用左右切换,总按键数更少。 */
export const NAV: NavItem[] = [
  { id: "search", label: "搜索", icon: "search" },
  { id: "home", label: "首页", icon: "home" },
  { id: "library", label: "媒体库", icon: "library" },
  { id: "favorites", label: "收藏", icon: "heart" },
  { id: "discover", label: "发现", icon: "compass" },
  { id: "downloads", label: "下载", icon: "download" },
];

/** 导航轨底部(管理区)。 */
export const NAV_FOOT: NavItem[] = [
  { id: "servers", label: "服务器", icon: "server" },
  { id: "settings", label: "设置", icon: "settings" },
];

/** 导航轨要不要渲染。播放页和详情页全屏,轨不出现。 */
export const FULLSCREEN_PAGES: ReadonlySet<PageId> = new Set<PageId>([
  "player",
  "detail",
  "episode",
]);

/** 导航轨上的页 = **平级**,互相跳不叠栈。
 *  否则「首页→媒体库→收藏」之后要按三次返回才退出,而用户预期是一次。
 *  ★ 这和「全屏」是两件事:线路管理有导航轨(是管理页),但它从服务器页进来,
 *    必须叠栈,否则返回键会直接退出应用而不是退回服务器页。 */
export const RAIL_PAGES: ReadonlySet<PageId> = new Set<PageId>(
  [...NAV, ...NAV_FOOT].map((n) => n.id),
);
