import type { ReactElement } from "react";
import {
  IconHome,
  IconLibrary,
  IconHeart,
  IconDownload,
  IconRanking,
  IconCalendar,
  IconServer,
  IconSettings,
} from "./icons";

/** 路由 id。netdisk / anirss / addserver 是内部路由(不进侧栏):
 *  netdisk·anirss 登录对应源后进入。calendar 已提到侧栏(用户 2026-07-16)。 */
export type PageId =
  | "home"
  | "library"
  | "favorites"
  | "downloads"
  | "rankings"
  | "servers"
  | "settings"
  | "addserver"
  | "netdisk"
  | "anirss"
  | "calendar";

export type NavItem = {
  id: PageId;
  label: string;
  icon: (p: { size?: number; className?: string }) => ReactElement;
};

/** 侧栏主导航(草稿序):首页 / 媒体库 / 收藏 / 下载 / 排行榜 / 追剧日历。 */
export const NAV: NavItem[] = [
  { id: "home", label: "首页", icon: IconHome },
  { id: "library", label: "媒体库", icon: IconLibrary },
  { id: "favorites", label: "收藏", icon: IconHeart },
  { id: "downloads", label: "下载", icon: IconDownload },
  { id: "rankings", label: "排行榜", icon: IconRanking },
  { id: "calendar", label: "追剧日历", icon: IconCalendar },
];

/** 侧栏底部(管理区):服务器 / 设置。 */
export const NAV_FOOT: NavItem[] = [
  { id: "servers", label: "服务器", icon: IconServer },
  { id: "settings", label: "设置", icon: IconSettings },
];
