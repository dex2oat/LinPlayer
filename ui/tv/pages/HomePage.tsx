import { useEffect, useState } from "react";
import {
  backdropUrl,
  listLatest,
  listNextUp,
  listResume,
  listRandom,
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
  const hero = useAsync(() => listRandom(5), []);
  const resume = useAsync(() => listResume(20), []);
  const next = useAsync(() => listNextUp(20), []);
  const libs = useAsync(() => views(), []);

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
  /* 焦点在 Hero 上时**暂停自动轮播** —— 用户正瞄着「播放」按下去,片子却换了,
     等于点了个自己没看见的东西。这是 Hero 轮播最容易挨骂的地方。 */
  const [held, setHeld] = useState(false);
  const it = items[i];

  useEffect(() => {
    if (items.length < 2 || held) return;
    const t = setInterval(() => setI((v) => (v + 1) % items.length), 12000);
    return () => clearInterval(t);
  }, [items.length, held]);

  if (!it) return <div className="hero sk" />;

  const step = (d: number) => setI((v) => (v + d + items.length) % items.length);

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
      {/* ★ on-art:文字直接压在封面上,没有渐变兜底,必须描边。
          亮场景的封面上白字不描边是真的读不了(用户实测)。 */}
      <div className="info on-art">
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
            onFocus={() => setHeld(true)}
            onEnter={() => go({ page: "detail", itemId: it.id })}
          >
            <Icon n="play" className="ic ic-btn" />
            播放
          </FocusItem>
          <FocusItem
            className="btn fx"
            onFocus={() => setHeld(true)}
            onEnter={() => go({ page: "detail", itemId: it.id })}
          >
            <Icon n="info" className="ic ic-btn" />
            详情
          </FocusItem>
          {/* ★ 明确的「换一片」入口。
              原来只有 12 秒自动轮播,用户想看下一部只能干等 —— 而遥控器上
              没有任何一个键在这里是有意义的。做成按钮而不是劫持左右方向键:
              方向键在按钮行里的语义是移动焦点,抢过来当轮播会让整页的手感不一致。 */}
          {items.length > 1 && (
            <FocusItem
              className="btn ico fx"
              onFocus={() => setHeld(true)}
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
        <div className="rowhead">
          <div className="t">{title}</div>
        </div>
        <div style={{ fontSize: 17, color: "var(--tv-ink-3)", padding: "12px 0" }}>
          没加载出来:{err.message}
        </div>
      </div>
    );
  }

  return (
    <div className="row">
      <div className="rowhead">
        <div className="t">{title}</div>
      </div>
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

function LatestRow({
  lib,
  session,
  go,
}: {
  lib: Item;
  session: LoginResult;
  go: (r: Route) => void;
}) {
  const { data, err } = useAsync(() => listLatest(lib.id, 20), [lib.id]);
  /* ★ 标题不写「· 最近添加」:首页各媒体库行默认就是按最新排,是常识,
     写出来只是把每一行的标题都拉长一截,远看还更难扫。
     ★ 用竖版海报:这些行里装的是剧和电影,人家的封面本来就是竖的。 */
  return <Row title={lib.name} items={data} err={err} session={session} go={go} poster />;
}
