import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { setFocus } from "@noriginmedia/norigin-spatial-navigation";
import {
  listFavorites,
  setFavorite,
  type Item,
  type LoginResult,
} from "@shared/api";
/* ★ 排序规则**复用桌面端那份纯逻辑模块**,不在 TV 侧再写一遍。
   它里面钉着一条在真实服务器上实测出来的结论(UHD fork 无视收藏接口上的 SortBy),
   抄一份到这里 = 两份规则,以后只改一边的话 TV 端会悄悄退回"排序看起来没生效"。
   模块只 import 一个 type,没有任何桌面依赖被拖进 TV 包。 */
import { SORTS, sortItems, type SortId } from "@shared/favorites-sort";
import type { Route } from "../App";
import { onTvKey } from "../app/focus";
import { Icon } from "../app/icons";
import { CardPoster, CardWide } from "../components/Cards";
import { FocusBoundary, FocusColumn, FocusItem } from "../components/Focus";
import { useAsync } from "../lib/useAsync";

/** 收藏(草稿 07)。结构上是媒体库的简化版:没有类型筛选,只有排序。

    ★ **排序必须本地做**。某些 Emby fork 在 `Filters=IsFavorite` 上不认服务端 SortBy
      (发 SortName 还是 CommunityRating 返回的顺序一模一样),PC 端已经踩过。
      收藏封顶两千条,本地排零压力且在任何服务器上都成立 —— 见 favorites-sort.ts。
    ★ 排序入口和媒体库同一套:**单焦点项 + 右侧面板**,不做横排 chip。
      遥控器的代价是焦点格数,横排四个排序 chip 够到最后一个要按三次。
    ★ 「取消收藏」走菜单键 → 面板。它**不是唯一入口**(详情页有收藏按钮),
      所以即便壳还没转发 KEYCODE_MENU 也不会有能力丢失 —— 只是少了个快捷方式。
    ★ **按类型分区**(用户 2026-07-20 评审):分集用横卡,剧/电影用竖版海报。
      一个网格混着放的结果是横竖封面互相裁 —— 剧的竖版海报塞进 16:9 要裁掉大半张脸,
      集的 16:9 截图塞进 2:3 两边留黑边。两种封面本来就是两种比例,不该共用一个网格。 */

/** 默认 = 服务端返回的原始顺序(约等于收藏时间倒序)。
 *  它不在 SORTS 里,因为"不排"本来就不需要一个排序键。 */
type Sort = SortId | null;

export default function FavoritesPage({
  session,
  go,
}: {
  session: LoginResult;
  go: (r: Route) => void;
}) {
  /* 只在进页时拉一次:排序是本地的,切档不该再打一次网络。 */
  const fav = useAsync(() => listFavorites(), []);
  /* 取消收藏后要把那张卡从网格里拿掉,所以列表要能改 → 单独存一份可变副本。 */
  const [removed, setRemoved] = useState<Set<string>>(new Set());

  const [sort, setSort] = useState<Sort>(null);
  const [asc, setAsc] = useState(false);
  const [panel, setPanel] = useState(false);
  const [menu, setMenu] = useState<Item | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const items = useMemo(
    () => (fav.data ?? []).filter((it) => !removed.has(it.id)),
    [fav.data, removed],
  );
  const shown = useMemo(() => (sort ? sortItems(items, sort, asc) : items), [items, sort, asc]);

  /* 分集 vs 剧/电影。分集的封面本来就是 16:9 截图,剧和电影的本来就是竖版海报。 */
  const eps = useMemo(() => shown.filter((it) => it.type_ === "Episode"), [shown]);
  const rest = useMemo(() => shown.filter((it) => it.type_ !== "Episode"), [shown]);

  /* 菜单键要对"现在焦点落在哪张卡"生效。CardWide / CardPoster 没有 onFocus 出口,
     而 components/ 是不许改的 → 从 DOM 反查:焦点态那一项带 .foc,而两个分区里的卡片
     就是按数组顺序渲染的直接子节点,序号即索引。
     ponytail: 真要多处用就给 Cards 加个 onFocus 透传,这里一处不值当动公共组件。 */
  const epRef = useRef<HTMLDivElement>(null);
  const restRef = useRef<HTMLDivElement>(null);
  const focusedItem = useCallback((): Item | null => {
    for (const [ref, list] of [
      [epRef, eps],
      [restRef, rest],
    ] as const) {
      const i = [...(ref.current?.children ?? [])].findIndex((n) =>
        n.classList.contains("foc"),
      );
      if (i >= 0) return list[i] ?? null;
    }
    return null;
  }, [eps, rest]);

  const say = useCallback((m: string) => {
    setToast(m);
    setTimeout(() => setToast(null), 3000);
  }, []);

  /* 面板一卸载焦点就在树上没有落点了 —— 那是 TV 最经典的 P0(遥控器整个失灵)。
     显式送回排序入口。 */
  const closeSort = useCallback(() => {
    setPanel(false);
    void setFocus("FAV_SORT");
  }, []);

  useEffect(
    () =>
      onTvKey((k) => {
        if (k === "menu") {
          if (!panel && !menu) setMenu(focusedItem());
          return;
        }
        if (k !== "back") return;
        /* 面板开着就先收面板,收完不再往下走(否则一次返回退两层)。 */
        if (menu) setMenu(null);
        else if (panel) closeSort();
      }),
    [panel, menu, focusedItem, closeSort],
  );

  const cancelFav = (it: Item) => {
    setMenu(null);
    setFavorite(it.id, false)
      .then(() => {
        setRemoved((s) => new Set(s).add(it.id));
        say(`已取消收藏 ${it.name}`);
      })
      .catch((e) => say(String(e)));
  };

  const label = sort ? SORTS.find((s) => s.id === sort)!.label : "收藏时间";
  const cond = sort ? `${label} ${asc ? "↑" : "↓"}` : "收藏时间 ↓";

  return (
    <>
      <FocusColumn focusKey="FAV">
        <div style={{ display: "flex", alignItems: "baseline", gap: 20, marginBottom: 30 }}>
          <div className="ptitle" style={{ margin: 0 }}>
            收藏
          </div>
          {items.length > 0 && (
            <div style={{ fontSize: 19, color: "var(--tv-ink-3)" }}>{items.length} 项</div>
          )}
        </div>

        {/* 收藏为空时连排序入口都不画:没有东西可排,那颗 chip 只会白占一个焦点位。 */}
        {items.length > 0 && (
          <div className="filters" style={{ alignItems: "center" }}>
            <FocusItem
              focusKey="FAV_SORT"
              className="fchip on"
              style={{ height: 60, padding: "0 30px" }}
              autoFocus
              onEnter={() => setPanel(true)}
            >
              <Icon n="filter" className="ic" />
              筛选与排序
            </FocusItem>
            {/* 当前条件常驻但**不可聚焦**:状态要看得见,但不该花按键去够。 */}
            <div style={{ fontSize: 17, color: "var(--tv-ink-3)" }}>{cond}</div>
          </div>
        )}

        {fav.data === null ? (
          <div className="grid poster c6">
            {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map((k) => (
              <div key={k} className="cell">
                <div className="th sk" />
              </div>
            ))}
          </div>
        ) : items.length === 0 ? (
          <Empty go={go} />
        ) : (
          <>
            {/* ★ 空的那一区**整段不渲染**(标题也不留):只收藏了剧的人看见一个空的
                「分集」标题,只会以为收藏丢了。 */}
            {eps.length > 0 && (
              <Section title="分集" count={eps.length} r={epRef}>
                {eps.map((it) => (
                  <CardWide
                    key={it.id}
                    it={it}
                    session={session}
                    showProgress
                    /* 收藏的分集直接进集详情页。走 detail 的话会落进剧集分支,
                       而分集条目没有 children —— 那是一页空的。 */
                    onEnter={() => go({ page: "episode", itemId: it.id })}
                  />
                ))}
              </Section>
            )}
            {rest.length > 0 && (
              <Section title="剧集与电影" count={rest.length} r={restRef}>
                {rest.map((it) => (
                  <CardPoster
                    key={it.id}
                    it={it}
                    session={session}
                    onEnter={() => go({ page: "detail", itemId: it.id })}
                  />
                ))}
              </Section>
            )}
          </>
        )}
      </FocusColumn>

      {panel && (
        <FocusBoundary className="panel" focusKey="FAV_PANEL" onBack={closeSort}>
          <div className="ph">排序</div>
          <div className="scroll">
            <FocusColumn>
              <div className="grp">排序方式</div>
              <PanelRow on={sort === null} label="收藏时间" onEnter={() => setSort(null)} />
              {SORTS.map((s) => (
                <PanelRow
                  key={s.id}
                  on={sort === s.id}
                  label={s.label}
                  onEnter={() => setSort(s.id)}
                />
              ))}

              {/* 方向只对"真的在本地排"的档有意义:默认档就是服务端给的顺序,反转它
                  只会得到一份没人要的倒序,还让"收藏时间 ↑"这种标签看起来像个功能。 */}
              {sort && (
                <>
                  <div className="grp">方向</div>
                  <PanelRow on={!asc} label="降序" onEnter={() => setAsc(false)} />
                  <PanelRow on={asc} label="升序" onEnter={() => setAsc(true)} />
                </>
              )}
            </FocusColumn>
          </div>
        </FocusBoundary>
      )}

      {menu && (
        <FocusBoundary className="panel" focusKey="FAV_MENU" onBack={() => setMenu(null)}>
          <div className="ph">{menu.name}</div>
          <div className="scroll">
            <FocusItem className="pitem" autoFocus onEnter={() => {
              const it = menu;
              setMenu(null);
              go({ page: "detail", itemId: it.id });
            }}>
              查看详情
            </FocusItem>
            <FocusItem className="pitem" onEnter={() => cancelFav(menu)}>
              <span style={{ color: "var(--danger)" }}>取消收藏</span>
            </FocusItem>
          </div>
        </FocusBoundary>
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/* ------------------------------------------------------------ */

/** 一个类型分区。卡片是**换行铺满**而不是 .track 单行横滚 ——
 *  收藏是个"全都在这儿"的页面,横滚一行会把大半藏在屏幕外。
 *  卡片自带固定宽(.card169 320 / .card23 220),flex-wrap 就够铺,不用再上 .grid。 */
function Section({
  title,
  count,
  r,
  children,
}: {
  title: string;
  count: number;
  r: React.RefObject<HTMLDivElement | null>;
  children: React.ReactNode;
}) {
  return (
    <div className="row">
      <div className="rowhead">
        <div className="t">{title}</div>
        <div style={{ fontSize: 17, color: "var(--tv-ink-3)" }}>{count} 项</div>
      </div>
      <div ref={r} style={WRAP}>
        {children}
      </div>
    </div>
  );
}

const WRAP: React.CSSProperties = { display: "flex", flexWrap: "wrap", gap: "32px 28px" };

/** 空态。**不画插画** —— 客厅里一张占半屏的灰色矢量图只会让人以为页面挂了,
 *  一句话加一个能按的大按钮就够,而且按钮天然接住了焦点(否则焦点无处可落)。 */
function Empty({ go }: { go: (r: Route) => void }) {
  return (
    <div style={{ paddingTop: 120, textAlign: "center" }}>
      <div style={{ fontSize: 26, color: "var(--tv-ink-2)", marginBottom: 30 }}>
        还没有收藏
      </div>
      <div className="btnrow" style={{ justifyContent: "center" }}>
        <FocusItem className="btn pri fx" autoFocus onEnter={() => go({ page: "library" })}>
          <Icon n="library" className="ic ic-btn" />
          去媒体库看看
        </FocusItem>
      </div>
    </div>
  );
}

function PanelRow({
  on,
  label,
  onEnter,
}: {
  on: boolean;
  label: string;
  onEnter: () => void;
}) {
  return (
    <FocusItem className={`pitem${on ? " on" : ""}`} onEnter={onEnter}>
      {label}
      {on && <span className="r">✓</span>}
    </FocusItem>
  );
}
