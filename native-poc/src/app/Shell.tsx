import { useState } from "react";
import { type Item, type LoginResult, type SourceEntry, setActiveServer } from "../lib/api";
import SearchOverlay from "../components/SearchOverlay";
import { useTheme } from "../theme/theme";
import Sidebar from "./Sidebar";
import { type PageId } from "./nav";
import HomePage from "../pages/HomePage";
import LibraryPage from "../pages/LibraryPage";
import DetailPage from "../pages/DetailPage";
import FavoritesPage from "../pages/FavoritesPage";
import RankingsPage from "../pages/RankingsPage";
import DownloadsPage from "../pages/DownloadsPage";
import NetdiskPage from "../pages/NetdiskPage";
import ServersPage from "../pages/ServersPage";
import AddServerPage from "../pages/AddServerPage";
import SettingsPage from "../pages/SettingsPage";
import AniRssPage from "../pages/AniRssPage";
import CalendarPage from "../pages/CalendarPage";

type Props = {
  session: LoginResult;
  connected: boolean;
  onPlay: (it: Item) => void;
  onPlaySource: (entry: SourceEntry) => void;
  onSessionChange: () => void;
  searchOpen: boolean;
  onSearch: () => void;
  onCloseSearch: () => void;
};

export default function Shell({
  session,
  connected,
  onPlay,
  onPlaySource,
  onSessionChange,
  searchOpen,
  onSearch,
  onCloseSearch,
}: Props) {
  const { theme, setTheme, toggle } = useTheme();
  const [page, setPage] = useState<PageId>("home");
  const [collapsed, setCollapsed] = useState(false);
  const [libTarget, setLibTarget] = useState<Item | null>(null);
  const [detailStack, setDetailStack] = useState<Item[]>([]);
  const [reloadKey, setReloadKey] = useState(0);
  const detail = detailStack[detailStack.length - 1] ?? null;

  function nav(p: PageId) {
    setDetailStack([]);
    if (p === "library") setLibTarget(null);
    setPage(p);
  }
  function openLibrary(view: Item) {
    setDetailStack([]);
    setLibTarget(view);
    setPage("library");
  }
  const openDetail = (it: Item) => setDetailStack([it]);
  const pushDetail = (it: Item) => setDetailStack((s) => [...s, it]);
  const backDetail = () => setDetailStack((s) => s.slice(0, -1));

  /**
   * 聚合搜索的结果可能属于别的服务器。核层 item_detail/play 都走「当前活跃服务器」,
   * 不先切服务器就会拿 B 服的 itemId 去打 A 服 —— 必然 404 或播错片。
   * serverId 为空(本服结果)时不切,省一次往返。
   */
  async function openFromSearch(it: Item, serverId?: string) {
    onCloseSearch();
    if (serverId && serverId !== session.server) {
      try {
        await setActiveServer(serverId);
        onSessionChange();
      } catch {
        return; // 切服失败就别往下走,否则打错服务器
      }
    }
    openDetail(it);
  }

  const body = (() => {
    switch (page) {
      case "home":
        return (
          <HomePage
            session={session}
            onOpenLibrary={openLibrary}
            onOpenItem={openDetail}
            onPlay={onPlay}
            onSearch={onSearch}
            onRefresh={() => setReloadKey((k) => k + 1)}
            reloadKey={reloadKey}
          />
        );
      case "library":
        return (
          <LibraryPage
            session={session}
            view={libTarget}
            onPickView={setLibTarget}
            onBack={() => setLibTarget(null)}
            onOpenItem={openDetail}
            onSearch={onSearch}
          />
        );
      case "favorites":
        return <FavoritesPage session={session} onOpenItem={openDetail} onPlay={onPlay} />;
      case "rankings":
        return <RankingsPage />;
      case "downloads":
        return <DownloadsPage />;
      case "netdisk":
        return <NetdiskPage onPlay={onPlaySource} onBack={() => nav("servers")} />;
      case "anirss":
        return <AniRssPage onBack={() => nav("servers")} />;
      case "calendar":
        return <CalendarPage onBack={() => nav("settings")} />;
      case "servers":
        return (
          <ServersPage
            session={session}
            activeServer={session.server}
            onChanged={onSessionChange}
            onGoAdd={() => nav("addserver")}
          />
        );
      case "addserver":
        return (
          <AddServerPage
            // 登录的是文件源时直接进对应浏览页,不绕回服务器页(Emby 才需要刷会话)。
            onDone={(src) => {
              if (src) return nav(src);
              onSessionChange();
              nav("servers");
            }}
            onBack={() => nav("servers")}
          />
        );
      case "settings":
        return <SettingsPage theme={theme} setTheme={setTheme} onOpenCalendar={() => nav("calendar")} />;
    }
  })();

  return (
    <div className="app-surface">
      <div className="shell">
        <Sidebar
          page={page}
          onNav={nav}
          collapsed={collapsed}
          onToggleCollapse={() => setCollapsed((v) => !v)}
          serverName={session.server.replace(/^https?:\/\//, "")}
          connected={connected}
          onServerClick={() => nav("servers")}
          theme={theme}
          onToggleTheme={toggle}
        />
        <div className="content">
          <div className="immersive" />
          <div className="page" key={detail ? `d:${detail.id}` : page + (libTarget?.id ?? "")}>
            {detail ? (
              <DetailPage
                session={session}
                item={detail}
                onPlay={onPlay}
                onOpenChild={pushDetail}
                onBack={backDetail}
              />
            ) : (
              body
            )}
          </div>
        </div>
      </div>

      {/* 搜索浮层挂在 Shell 而非 App:它要用 openDetail(点结果进详情,不是直接开播)和切服务器。 */}
      {searchOpen && (
        <SearchOverlay
          session={session}
          onClose={onCloseSearch}
          onOpenItem={openFromSearch}
          onPlay={(it) => {
            onCloseSearch();
            onPlay(it);
          }}
        />
      )}
    </div>
  );
}
