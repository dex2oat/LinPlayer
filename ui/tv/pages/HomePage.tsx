import { useCallback, useEffect, useState } from "react";
import {
  backdropUrl,
  listLatest,
  listNextUp,
  listResume,
  listRandom,
  peekList,
  views,
  type Item,
  type LoginResult,
} from "@shared/api";
import type { Route } from "../App";
import { Icon } from "../app/icons";
import { CardPoster, CardWide } from "../components/Cards";
import { FocusColumn, FocusItem, FocusRow } from "../components/Focus";
import { useAsync } from "../lib/useAsync";

/** 首页。Hero 随机推荐 + 若干横向行。

    ★ Hero **不打「随机推荐」标签**,也**不放继续观看** —— 下面已经有整整一行了,
      重复占掉这一屏最贵的位置。
    ★ Hero 上**不画渐变也不画半透明底**:文字直接落在封面上,信息块只占左下角。
      封面是主角,控件让位。 */
export default function HomePage({
  session,
  go,
}: {
  session: LoginResult;
  go: (r: Route) => void;
}) {
  /* ★ 每块都先偷看 api.ts 的 5 分钟 TTL 列表缓存,命中就直接画 ——
     返回键是 TV 的主交互,每次退回首页整屏重新骨架化正是用户说的「每次打开都要更新」。

     ★★ key 必须与 api.ts 里 `memo(...)` 的第一个参数**逐字相同**,且第二参数要对上:
        listRandom(5) → "random:5" / listResume(20) → "resume:20" /
        listNextUp(20) → "nextUp:20" / views() → "views"。
        写错**不报错**,只是永远不命中 —— 静默退回改造前的行为。改这里的数字时
        务必把 key 一起改。 */
  const hero = useAsync(() => listRandom(5), [], () => peekList<Item[]>("random:5"));
  const resume = useAsync(() => listResume(20), [], () => peekList<Item[]>("resume:20"));
  const next = useAsync(() => listNextUp(20), [], () => peekList<Item[]>("nextUp:20"));
  const libs = useAsync(() => views(), [], () => peekList<Item[]>("views"));

  return (
    <FocusColumn focusKey="HOME">
      <Hero items={hero.data ?? []} session={session} go={go} />

      <Row title="继续观看" items={resume.data} err={resume.err} session={session} go={go} progress />
      <Row title="接下来看" items={next.data} err={next.err} session={session} go={go} />

      {/* 每个媒体库一行「最近添加」。库表回来了才知道要开几行,
          但每一行的内容各自加载 —— 不等所有库都回来。 */}
      {(libs.data ?? []).map((lib) => (
        <LatestRow key={lib.id} lib={lib} session={session} go={go} />
      ))}
    </FocusColumn>
  );
}

/* ------------------------------------------------------------ */

function Hero({
  items,
  session,
  go,
}: {
  items: Item[];
  session: LoginResult;
  go: (r: Route) => void;
}) {
  const [i, setI] = useState(0);
  /* 焦点在 Hero 的**哪个**按钮上(null = 焦点不在 Hero)。
     ★ 原来这里是个 `held` 布尔,只在 onFocus 里置 true,**没有任何地方置回 false** ——
       首页一进来 autoFocus 就落在「播放」上,于是轮播从第一秒起就永久停摆。
       用户报的「不能自动切换」是这个,不是定时器时长的问题。
     ★ 记「第几个」而不是「在不在」,是因为下面的右键循环要知道焦点是否已经在最后一个上。 */
  const [focusIdx, setFocusIdx] = useState<number | null>(null);
  const it = items[i];

  const step = useCallback(
    (d: number) => setI((v) => (v + d + items.length) % items.length),
    [items.length],
  );

  useEffect(() => {
    /* 焦点在 Hero 上时不自动切:用户正瞄着「播放」按下去,片子却换了,
       等于点了个自己没看见的东西。这是 Hero 轮播最容易挨骂的地方。
       8s 而不是原来的 12s —— 12s 在电视上是"看着像坏了"的量级。 */
    if (items.length < 2 || focusIdx !== null) return;
    const t = setInterval(() => step(1), 8000);
    return () => clearInterval(t);
  }, [items.length, focusIdx, step]);

  /* ★ 一直往右按 = 循环换片。
     Hero 这一行右边再没有别的功能页了,方向键在那儿是**死键** —— 按下去毫无反应,
     用户不知道是没做还是坏了。既然是死键,就把它接到最需要的动作上。
     只在焦点已经落在**最后一个**按钮上时才拦:在此之前右键仍然是正常的移动焦点,
     整页手感不会因为 Hero 特殊而割裂。
     capture 阶段 + stopPropagation:焦点库是在 window 冒泡阶段监听的,
     不在 capture 拦就已经晚了(同 ProgressBar 里那条快进快退的做法)。 */
  /* 按钮:播放 / 详情 / 换一片(最后那个只有多于一部时才在)。
     写成"数出来"而不是硬编 2 —— 以后往这一行加按钮时,忘了同步这个数的表现是
     右键循环挪到了倒数第二个按钮上,而那是个**看不出来**的错。 */
  const lastIdx = (items.length > 1 ? 3 : 2) - 1;
  useEffect(() => {
    if (focusIdx === null || items.length < 2) return;
    const h = (e: KeyboardEvent) => {
      if (e.key !== "ArrowRight" || focusIdx !== lastIdx) return;
      e.stopPropagation();
      e.preventDefault();
      step(1);
    };
    window.addEventListener("keydown", h, true);
    return () => window.removeEventListener("keydown", h, true);
  }, [focusIdx, lastIdx, items.length, step]);

  if (!it) return <div className="hero sk" />;

  return (
    <div className="hero">
      {/* ★ 所有候选图都挂着,只切 opacity 做交叉淡化。
          只渲染当前那张的话,换图时新图要现拉现解码 —— 中间那一瞬是空的,
          表现为"闪一下黑",比没有动画还难看。 */}
      {items.map((x, n) => (
        <img
          key={x.id}
          className={`bg${n === i ? " show" : ""}`}
          src={backdropUrl(session, x.id, 1600)}
          alt=""
        />
      ))}
      {/* 文字直接落在封面上:不画渐变、不加底、不描边。
          用户 2026-07-20 逐条否掉了这三种(见 tv.css 里那段记录)。 */}
      <div className="info">
        <h3>{it.name}</h3>
        <div className="meta">
          {it.rating != null && <span className="score">{it.rating.toFixed(1)}</span>}
          {it.year != null && <span>{it.year}</span>}
          {it.genres.slice(0, 3).map((g) => (
            <span key={g}>{g}</span>
          ))}
        </div>
        <div className="btnrow">
          <FocusItem
            className="btn pri fx"
            autoFocus
            onFocus={() => setFocusIdx(0)}
            onBlur={() => setFocusIdx((v) => (v === 0 ? null : v))}
            onEnter={() => go({ page: "detail", itemId: it.id })}
          >
            <Icon n="play" className="ic ic-btn" />
            播放
          </FocusItem>
          <FocusItem
            className="btn fx"
            onFocus={() => setFocusIdx(1)}
            onBlur={() => setFocusIdx((v) => (v === 1 ? null : v))}
            onEnter={() => go({ page: "detail", itemId: it.id })}
          >
            <Icon n="info" className="ic ic-btn" />
            详情
          </FocusItem>
          {/* 「换一片」按钮保留:右键循环是给会摸索的人的快捷方式,
              但一个看得见的入口才是所有人都能发现的那条路。 */}
          {items.length > 1 && (
            <FocusItem
              className="btn ico fx"
              onFocus={() => setFocusIdx(2)}
              onBlur={() => setFocusIdx((v) => (v === 2 ? null : v))}
              onEnter={() => step(1)}
            >
              <Icon n="refresh" className="ic ic-btn" />
            </FocusItem>
          )}
        </div>
      </div>
      <div className="dots">
        {items.map((x, n) => (
          <i key={x.id} className={n === i ? "on" : ""} />
        ))}
      </div>
    </div>
  );
}

function Row({
  title,
  items,
  session,
  go,
  progress,
  poster,
  err,
  onOpen,
}: {
  title: string;
  items: Item[] | null;
  session: LoginResult;
  go: (r: Route) => void;
  progress?: boolean;
  /** 竖版海报行(剧/电影)。默认横版 —— 横版只给**分集**用(集封面本来就是 16:9 截图)。 */
  poster?: boolean;
  /** 这一行自己的加载错误。**必须传** —— 见下面为什么。 */
  err?: Error | null;
  /** 行标题可进入(媒体库行)。传了标题就变成一个焦点位,确认键进那个库。 */
  onOpen?: () => void;
}) {
  /* 加载中给骨架,**空数组整行不渲染** ——
     "继续观看(空)"这种标题只是占位噪音,新用户首页会挂三个空标题。 */
  if (items && items.length === 0) return null;

  /* ★ 失败和加载中必须分开显示。
     原来只看 `items === null`,而 useAsync 在失败时 data 也是 null ——
     于是**失败的行会永远停在骨架上**,变成一行永不消失的灰块,
     用户完全看不出是"还在转"还是"挂了"。实测撞到过:某个媒体库的
     list_latest 十几秒不返回,那一行就一直是六个灰盒子。 */
  if (err) {
    return (
      <div className="row">
        <RowHead title={title} onOpen={onOpen} />
        <div style={{ fontSize: 17, color: "var(--tv-ink-3)", padding: "12px 0" }}>
          没加载出来:{err.message}
        </div>
      </div>
    );
  }

  return (
    <div className="row">
      <RowHead title={title} onOpen={onOpen} />
      {!items ? (
        <div className="track">
          {[0, 1, 2, 3, 4, 5].map((k) => (
            <div key={k} className={poster ? "card23" : "card169"}>
              <div className="th sk" />
            </div>
          ))}
        </div>
      ) : (
        <FocusRow>
          {items.map((it) =>
            poster ? (
              <CardPoster
                key={it.id}
                it={it}
                session={session}
                onEnter={() => go({ page: "detail", itemId: it.id })}
              />
            ) : (
              <CardWide
                key={it.id}
                it={it}
                session={session}
                showProgress={progress}
                onEnter={() => go({ page: "detail", itemId: it.series_id ?? it.id })}
              />
            ),
          )}
        </FocusRow>
      )}
    </div>
  );
}

/** 行标题。媒体库行的标题是**可以按进去的** ——
 *
 *  ★ 在此之前,首页上看得到「某个库最近加了什么」,却没有任何办法从这里进那个库:
 *    只能退到导航轨、进媒体库页、再挑一次库。用户的原话是「这非常不合理」,是对的。
 *  ★ 为什么做成标题本身而不是行尾加一个「查看全部」:行尾要按过整行卡片才够得着
 *    (一行 20 张),而标题就在焦点从上面下来的必经之路上,零额外按键。
 *  ★ 非媒体库行(继续观看/接下来看)没有"库"这个概念,不给焦点位 ——
 *    多一个按不出东西的焦点位,只是让每一行都多挡一下。 */
function RowHead({ title, onOpen }: { title: string; onOpen?: () => void }) {
  if (!onOpen) {
    return (
      <div className="rowhead">
        <div className="t">{title}</div>
      </div>
    );
  }
  return (
    <div className="rowhead">
      {/* 箭头用字形不用图标:图标集里没有 chevron,为一个装饰性尖角去扩 sprite 不划算。 */}
      <FocusItem className="t rowlink" onEnter={onOpen}>
        {title}
        <span className="chev" aria-hidden>
          ›
        </span>
      </FocusItem>
    </div>
  );
}

function LatestRow({
  lib,
  session,
  go,
}: {
  lib: Item;
  session: LoginResult;
  go: (r: Route) => void;
}) {
  /* key 抄自 api.ts 的 `latest:${parentId}:${limit}` —— 两个参数都要编进去。 */
  const { data, err } = useAsync(
    () => listLatest(lib.id, 20),
    [lib.id],
    () => peekList<Item[]>(`latest:${lib.id}:20`),
  );
  /* ★ 标题不写「· 最近添加」:首页各媒体库行默认就是按最新排,是常识,
     写出来只是把每一行的标题都拉长一截,远看还更难扫。
     ★ 用竖版海报:这些行里装的是剧和电影,人家的封面本来就是竖的。 */
  return (
    <Row
      title={lib.name}
      items={data}
      err={err}
      session={session}
      go={go}
      poster
      onOpen={() => go({ page: "library", parentId: lib.id })}
    />
  );
}
