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
import { CardWide } from "../components/Cards";
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

      <Row title="继续观看" items={resume.data} session={session} go={go} progress />
      <Row title="接下来看" items={next.data} session={session} go={go} />

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
  const it = items[i];

  /* 轮播。焦点在 Hero 上时不该自己换片(用户正要按播放,片子换了) ——
     这里只在没被聚焦时走。 */
  useEffect(() => {
    if (items.length < 2) return;
    const t = setInterval(() => setI((v) => (v + 1) % items.length), 12000);
    return () => clearInterval(t);
  }, [items.length]);

  if (!it) return <div className="hero sk" />;

  return (
    <div className="hero">
      <img className="bg" src={backdropUrl(session, it.id, 1600)} alt="" />
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
            onEnter={() => go({ page: "detail", itemId: it.id })}
          >
            <Icon n="play" className="ic ic-btn" />
            播放
          </FocusItem>
          <FocusItem
            className="btn fx"
            onEnter={() => go({ page: "detail", itemId: it.id })}
          >
            <Icon n="info" className="ic ic-btn" />
            详情
          </FocusItem>
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
}: {
  title: string;
  items: Item[] | null;
  session: LoginResult;
  go: (r: Route) => void;
  progress?: boolean;
}) {
  /* 加载中给骨架,**空数组整行不渲染** ——
     "继续观看(空)"这种标题只是占位噪音,新用户首页会挂三个空标题。 */
  if (items && items.length === 0) return null;

  return (
    <div className="row">
      <div className="rowhead">
        <div className="t">{title}</div>
      </div>
      {!items ? (
        <div className="track">
          {[0, 1, 2, 3, 4].map((k) => (
            <div key={k} className="card169">
              <div className="th sk" />
            </div>
          ))}
        </div>
      ) : (
        <FocusRow>
          {items.map((it) => (
            <CardWide
              key={it.id}
              it={it}
              session={session}
              showProgress={progress}
              onEnter={() => go({ page: "detail", itemId: it.series_id ?? it.id })}
            />
          ))}
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
  const { data } = useAsync(() => listLatest(lib.id, 20), [lib.id]);
  return (
    <Row title={`${lib.name} · 最近添加`} items={data} session={session} go={go} />
  );
}
