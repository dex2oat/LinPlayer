import { useCallback, useEffect, useRef, useState } from "react";
import {
  fmtTime,
  reportProgress,
  seek,
  setPause,
  setTrack,
  status as getStatus,
  stopPlayback,
  tracks as getTracks,
  type Status,
  type Track,
} from "@shared/api";
import { pollTracks } from "@shared/track-poll";
import { onTvKey } from "../app/focus";
import { Icon, type IconName } from "../app/icons";
import { FocusBoundary, FocusColumn, FocusItem, FocusRow } from "../components/Focus";

/** 播放页 OSD。

    ★ 整屏是**透明**的 —— 底下是原生播放器(桌面是 mpv 顶层窗,安卓是 SurfaceView),
      这一层只画控件,不画任何底色。
    ★ **不用渐变**:上下栏全透明,每个控件自己是不透明块(统一 --tv-panel,与面板同色)。
      全屏渐变每帧都要重新合成,机顶盒上是笔冤枉开销,渐变边界远看还是糊的。
      代价是标题和时间成了裸文字 → 它们必须**自带不透明底**,不然亮场景上读不了。 */

type Panel = null | "sub" | "audio" | "danmaku" | "more";

export default function PlayerPage({
  title,
  onBack,
}: {
  title?: string;
  onBack: () => void;
}) {
  const [st, setSt] = useState<Status | null>(null);
  const [trk, setTrk] = useState<Track[]>([]);
  const [panel, setPanel] = useState<Panel>(null);
  /* OSD 默认**收起**:进来就该看见画面,不是看见一层控件。 */
  const [osd, setOsd] = useState(false);
  const hideAt = useRef(0);
  /* ★ eof 收尾只许跑一次。轮询每秒一发,而 eof 一旦为 true 就**一直**为 true
     (mpv keep-open=yes 停在最后一帧),不加锁就是每秒一发 stop_playback ——
     每一发都会重置 Emby 进度、重打一次 Trakt/Bangumi 上报。
     用 ref 不用 state:state 要等下一次渲染才生效,而下一次轮询在 1s 后,足够重入。 */
  const ended = useRef(false);

  /* ★ 让整条渲染链透明,否则原生视频被 UI 层盖死 —— 黑屏但有声音,且不报错。
     开关放在这里(而不是全局常开)是因为其它页面要那个不透明底色。 */
  useEffect(() => {
    document.documentElement.classList.add("playing");
    return () => document.documentElement.classList.remove("playing");
  }, []);

  /* 状态轮询。1s 够了 —— 进度条一秒动一格,人眼在三米外分辨不出更细的。
     轮询而不是订阅事件:核层没有 status 推送通道,而且轮询在页面卸载时天然停掉。 */
  useEffect(() => {
    let alive = true;
    const t = setInterval(async () => {
      try {
        const s = await getStatus();
        if (!alive) return;
        setSt(s);

        /* ★ 正常播完自动收尾。走的是和按返回键**完全同一条路**(stopPlayback + onBack),
           只是位置传 `duration` 而不是 `time`:
           - mpv 停在最后一帧时 time 通常差最后零点几秒,传 time 算出来是 99%,
             服务端不算「看完」,Trakt/Bangumi 的看完一次都不会触发(用户报的正是这个);
           - 传 duration 才是 100%,核层才收得住尾。
           ★ 本页**没有**自动连播下一集(OSD 的「上一集/下一集」两个按钮至今没有 onEnter,
             核层也没有对应命令),所以这里不去"复用"一个不存在的东西 —— 直接退出播放页。 */
        if (s.eof && !ended.current) {
          ended.current = true;
          clearInterval(t);
          void stopPlayback(s.duration).finally(onBack);
          return;
        }

        /* 上报进度给 Emby。★ 必须带 PlaySessionId 且与取流会话同 id ——
           核层已经在 play() 里处理,这里只管按节奏喂 pos。 */
        void reportProgress(s.time, s.paused).catch(() => {});
      } catch {
        /* 播放器还没起来时 status 会报错,不该刷屏也不该弹错。 */
      }
    }, 1000);
    return () => {
      alive = false;
      clearInterval(t);
    };
    /* onBack 来自 App 的 useCallback([]),身份稳定 —— 列进依赖不会让轮询反复重启。 */
  }, [onBack]);

  /* 轨道列表要**探到稳定**,不能起播拉一次就定死 —— 外挂字幕要等核层收到
     mpv 的 FILE_LOADED 才挂得上,慢服务器上是起播后好几秒的事,那之前的快照
     里根本没有它们。逻辑与桌面共用一份,见 shared/track-poll.ts。 */
  useEffect(() => pollTracks(setTrk), []);

  /* OSD 自动收起。有面板开着时不收 —— 用户正在里面挑东西。 */
  useEffect(() => {
    if (!osd || panel) return;
    hideAt.current = Date.now() + 5000;
    const t = setInterval(() => {
      if (Date.now() >= hideAt.current) setOsd(false);
    }, 500);
    return () => clearInterval(t);
  }, [osd, panel]);

  const bump = useCallback(() => {
    setOsd(true);
    hideAt.current = Date.now() + 5000;
  }, []);

  const togglePause = useCallback(async () => {
    if (!st) return;
    await setPause(!st.paused);
    setSt({ ...st, paused: !st.paused });
    bump();
  }, [st, bump]);

  const jump = useCallback(
    async (d: number) => {
      if (!st) return;
      const p = Math.max(0, Math.min(st.duration || 0, st.time + d));
      await seek(p);
      setSt({ ...st, time: p });
      bump();
    },
    [st, bump],
  );

  /* 返回键:面板开着先关面板,OSD 开着先收 OSD,都没有才退出播放。
     ★ 一次退到底是 TV 上最容易挨骂的交互 —— 用户只想关掉字幕面板,结果整个退出了。 */
  useEffect(
    () =>
      onTvKey((k) => {
        if (k === "back") {
          if (panel) setPanel(null);
          else if (osd) setOsd(false);
          /* 同一把锁:eof 已经收过尾了就只退页,别再 stop 一次把 100% 改回 time。 */
          else if (ended.current) onBack();
          else {
            ended.current = true;
            void stopPlayback(st?.time ?? 0).finally(onBack);
          }
          return;
        }
        if (k === "playpause" || k === "play" || k === "pause") void togglePause();
        if (k === "ff") void jump(30);
        if (k === "rew") void jump(-10);
      }),
    [panel, osd, st, togglePause, jump, onBack],
  );

  /* 任意方向键唤出 OSD。TV 上没有鼠标移动这种"我还在"的信号,
     唤出的唯一途径就是按键。 */
  useEffect(() => {
    const h = () => bump();
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [bump]);

  const dur = st?.duration ?? 0;
  const pos = st?.time ?? 0;
  const pct = dur > 0 ? (pos / dur) * 100 : 0;
  const buf = dur > 0 ? ((st?.buffered ?? 0) / dur) * 100 : 0;

  return (
    <div className="osd">
      {/* 顶栏:全透明,标题块自带不透明底 */}
      {osd && (
        <div className="osd-top">
          <div className="tt">
            <div className="t">{title ?? "正在播放"}</div>
          </div>
        </div>
      )}

      {osd && !panel && (
        <FocusColumn focusKey="OSD">
          <div className="osd-bot">
            <ProgressBar pct={pct} buf={buf} onSeek={jump} />
            <div className="times">
              <span>{fmtTime(pos)}</span>
              <span className="r">{fmtTime(dur)}</span>
            </div>
            <FocusRow trackClass="ctrls">
              <CBtn icon="prev" label="上一集" />
              <CBtn icon="rew" label="快退" onEnter={() => jump(-10)} />
              <FocusItem className="cbtn big fx" autoFocus onEnter={togglePause}>
                <Icon n={st?.paused ? "play" : "pause"} className="ic ic-c" />
              </FocusItem>
              <CBtn icon="fwd" label="快进" onEnter={() => jump(30)} />
              <CBtn icon="next" label="下一集" />
              <div className="spring" />
              {/* ★ 右组必须**图标+文字** —— 裸图标用户第一反应是"那是什么"。
                  左组(上一集/快退/播放/快进/下一集)是通用约定,可以纯图标。 */}
              <WideBtn icon="sub" text="字幕" onEnter={() => setPanel("sub")} />
              <WideBtn icon="audio" text="音轨" onEnter={() => setPanel("audio")} />
              <WideBtn icon="danmaku" text="弹幕" onEnter={() => setPanel("danmaku")} />
              <WideBtn icon="more" text="更多" onEnter={() => setPanel("more")} />
            </FocusRow>
          </div>
        </FocusColumn>
      )}

      {/* 面板打开时 OSD 自动收起(上面用 !panel 控制),画面大部分露在外面,**没有黑色遮罩** */}
      {panel && (
        <TrackPanel
          kind={panel}
          tracks={trk}
          onPick={async (t) => {
            await setTrack(t.kind, t.id);
            setTrk(await getTracks());
            setPanel(null);
          }}
          onClose={() => setPanel(null)}
        />
      )}
    </div>
  );
}

/* ------------------------------------------------------------ */

function ProgressBar({
  pct,
  buf,
  onSeek,
}: {
  pct: number;
  buf: number;
  onSeek: (d: number) => void;
}) {
  /* 进度条是一个焦点位:落上去后左右键 = 快退/快进,不是移动焦点。
     这靠 FocusItem 拿不到方向键,所以自己听 —— 只在聚焦时生效。 */
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!focused) return;
    const h = (e: KeyboardEvent) => {
      if (e.key === "ArrowLeft") {
        e.stopPropagation();
        onSeek(-10);
      }
      if (e.key === "ArrowRight") {
        e.stopPropagation();
        onSeek(30);
      }
    };
    window.addEventListener("keydown", h, true);
    return () => window.removeEventListener("keydown", h, true);
  }, [focused, onSeek]);

  return (
    <FocusItem
      className="bar"
      focusClass="foc"
      onFocus={() => setFocused(true)}
      onEnter={() => {}}
    >
      <div className="buf" style={{ width: `${buf}%` }} />
      <div className="pl" style={{ width: `${pct}%` }} />
      <div className="kn" style={{ left: `${pct}%` }} />
    </FocusItem>
  );
}

function CBtn({
  icon,
  label,
  onEnter,
}: {
  icon: IconName;
  label: string;
  onEnter?: () => void;
}) {
  return (
    <FocusItem className="cbtn fx" onEnter={onEnter}>
      <Icon n={icon} className="ic ic-c" />
      <span style={{ position: "absolute", opacity: 0 }}>{label}</span>
    </FocusItem>
  );
}

function WideBtn({
  icon,
  text,
  onEnter,
}: {
  icon: IconName;
  text: string;
  onEnter: () => void;
}) {
  return (
    <FocusItem className="cbtn wide fx" onEnter={onEnter}>
      <Icon n={icon} className="ic ic-c" />
      <span>{text}</span>
    </FocusItem>
  );
}

function TrackPanel({
  kind,
  tracks,
  onPick,
  onClose,
}: {
  kind: Exclude<Panel, null>;
  tracks: Track[];
  onPick: (t: Track) => void;
  onClose: () => void;
}) {
  const TITLE: Record<string, string> = {
    sub: "字幕",
    audio: "音轨",
    danmaku: "弹幕",
    more: "更多",
  };
  const want = kind === "sub" ? "sub" : "audio";
  const list = tracks.filter((t) => t.kind === want);

  return (
    <FocusBoundary focusKey="PLAYER_PANEL" className="panel">
      <div className="ph">{TITLE[kind]}</div>
      <FocusColumn className="scroll">
        {kind === "sub" || kind === "audio" ? (
          list.length === 0 ? (
            <div className="pitem">没有可选的{TITLE[kind]}</div>
          ) : (
            list.map((t) => (
              <FocusItem
                key={t.id}
                className={`pitem${t.selected ? " on" : ""}`}
                onEnter={() => onPick(t)}
              >
                {t.title || t.lang || t.id}
                {t.selected && <span className="r">当前</span>}
              </FocusItem>
            ))
          )
        ) : (
          /* 弹幕 / 更多 还没接。**故意不画假开关** ——
             画了在评审时会被当成已经能用。 */
          <FocusItem className="pitem" onEnter={onClose}>
            这一组还没接线
          </FocusItem>
        )}
      </FocusColumn>
    </FocusBoundary>
  );
}
