import { useCallback, useEffect, useRef, useState } from "react";
import { currentSession, onAccountsChanged, type LoginResult } from "@shared/api";
import { applyTvScale, onTvKey } from "./app/focus";
import { TvIconSprite } from "./app/icons";
import { FULLSCREEN_PAGES, RAIL_PAGES, type PageId } from "./app/nav";
import PageBoundary from "./app/PageBoundary";
import PlayerPage from "./pages/PlayerPage";
import Rail from "./app/Rail";
import DetailPage from "./pages/DetailPage";
import DiscoverPage from "./pages/DiscoverPage";
import DownloadsPage from "./pages/DownloadsPage";
import EpisodePage from "./pages/EpisodePage";
import FavoritesPage from "./pages/FavoritesPage";
import HomePage from "./pages/HomePage";
import LibraryPage from "./pages/LibraryPage";
import LinesPage from "./pages/LinesPage";
import NetdiskPage from "./pages/NetdiskPage";
import OnboardingPage from "./pages/OnboardingPage";
import SearchPage from "./pages/SearchPage";
import ServersPage from "./pages/ServersPage";
import SettingsPage from "./pages/SettingsPage";

/** 一条路由。参数直接挂在上面,页面少、层级浅,不值当上路由库
 *  ——「装个 router 只为了三层页面」正是 PC 端刻意没做的事,TV 更没必要。 */
export type Route = {
  page: PageId;
  /** detail / episode 用 */
  itemId?: string;
  /** library 用 */
  parentId?: string;
  /** lines 用:账号主键(= AccountInfo.server) */
  serverId?: string;
  title?: string;
};

export default function App() {
  const rootRef = useRef<HTMLDivElement>(null);

  /* undefined = 还在问核层要会话(不能当"没登录"处理,否则每次启动都闪一下首启页) */
  const [session, setSession] = useState<LoginResult | null | undefined>(undefined);

  /* 用栈而不是单个 route:返回键要能一层层退回来。
     栈底恒为首页 —— 退到底再按返回是"退出应用",交给壳处理。 */
  const [stack, setStack] = useState<Route[]>([{ page: "home" }]);
  const route = stack[stack.length - 1];

  const go = useCallback((r: Route | PageId) => {
    const next: Route = typeof r === "string" ? { page: r } : r;
    /* 导航轨上的页是**平级**的,互相跳不叠栈;其余(详情/播放/线路管理…)才入栈。
       ★ 判据是「在不在导航轨上」,不是「全不全屏」—— 线路管理有导航轨但必须叠栈,
         否则从服务器页进去后按返回会直接退出应用,而不是退回服务器页。 */
    setStack((s) => (RAIL_PAGES.has(next.page) ? [next] : [...s, next]));
  }, []);

  const back = useCallback(() => {
    setStack((s) => (s.length > 1 ? s.slice(0, -1) : s));
  }, []);

  /* 1920 基准等比缩放 */
  useEffect(() => {
    if (rootRef.current) return applyTvScale(rootRef.current);
  }, []);

  /* 壳的返回键。★ 这条通道要 apps/android 的 Activity 先 emit,
     否则真机上 KEYCODE_BACK 被 Activity 吃掉,全站返回键失灵。 */
  useEffect(() => onTvKey((k) => k === "back" && back()), [back]);

  /* 会话。账号表变了要重问 —— 删掉最后一台服务器就该退回首启页。 */
  useEffect(() => {
    const load = () => currentSession().then(setSession).catch(() => setSession(null));
    load();
    return onAccountsChanged(load);
  }, []);

  if (session === undefined) {
    return (
      <div ref={rootRef} className="tv-app">
        <TvIconSprite />
      </div>
    );
  }

  /* 没有任何服务器 → 首次启动。此时不画导航轨:轨上八项一个都点不动,
     只会让用户在空页面之间转圈。 */
  if (!session) {
    return (
      <div ref={rootRef} className="tv-app">
        <TvIconSprite />
        <PageBoundary resetKey="onboarding">
          <OnboardingPage />
        </PageBoundary>
      </div>
    );
  }

  const full = FULLSCREEN_PAGES.has(route.page);

  return (
    <div ref={rootRef} className="tv-app">
      <TvIconSprite />
      {!full && <Rail page={route.page} onGo={go} />}
      <div className={`body${full ? " flush" : ""}`}>
        <PageBoundary resetKey={`${route.page}:${route.itemId ?? ""}`}>
          <Page route={route} session={session} go={go} back={back} />
        </PageBoundary>
      </div>
    </div>
  );
}

function Page({
  route,
  session,
  go,
  back,
}: {
  route: Route;
  session: LoginResult;
  go: (r: Route | PageId) => void;
  back: () => void;
}) {
  switch (route.page) {
    case "home":
      return <HomePage session={session} go={go} />;
    case "library":
      return <LibraryPage session={session} go={go} parentId={route.parentId} />;
    case "search":
      return <SearchPage session={session} go={go} />;
    case "favorites":
      return <FavoritesPage session={session} go={go} />;
    case "downloads":
      return <DownloadsPage />;
    case "discover":
      return <DiscoverPage session={session} go={go} />;
    case "detail":
      return <DetailPage session={session} go={go} itemId={route.itemId} />;
    case "episode":
      return <EpisodePage session={session} go={go} itemId={route.itemId} />;
    case "player":
      return <PlayerPage title={route.title} onBack={back} />;
    case "netdisk":
      return <NetdiskPage session={session} go={go} />;
    case "servers":
      return <ServersPage go={go} />;
    case "settings":
      return <SettingsPage go={go} />;
    case "lines":
      return <LinesPage go={go} serverId={route.serverId} />;
    default:
      return <Todo page={route.page} />;
  }
}

/** 还没落的页。**故意写成一眼能认出是未完成**,不做假 UI ——
 *  假 UI 在评审时会被当成"已经做好了"。 */
function Todo({ page }: { page: PageId }) {
  return (
    <div style={{ paddingTop: 40 }}>
      <div className="ptitle">{page}</div>
      <div className="psub">这一页还没落地。草稿见 docs/tv-drafts.html。</div>
    </div>
  );
}
