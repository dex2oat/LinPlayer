import { useEffect, useRef, type MutableRefObject } from "react";

export type DanmakuComment = { time: number; text: string; mode: number; color: number };
export type TimeSync = { base: number; stamp: number; paused: boolean };

type Active = { text: string; color: string; mode: number; born: number; width: number; lane: number; speed: number };

const DURATION = 8; // 滚动弹幕在屏时长(秒)
const FIXED_DUR = 5; // 顶/底弹幕停留时长

/** Canvas 弹幕层:自跑 rAF,时间从 timeSync 插值(平滑于 500ms 轮询),同步 mpv 播放。 */
export function DanmakuLayer({
  comments,
  timeSync,
  enabled,
}: {
  comments: DanmakuComment[];
  timeSync: MutableRefObject<TimeSync>;
  enabled: boolean;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const stateRef = useRef({ cursor: 0, active: [] as Active[], lastT: -1 });

  // 换视频/重载弹幕 → 重置游标与在屏弹幕
  useEffect(() => {
    stateRef.current = { cursor: 0, active: [], lastT: -1 };
  }, [comments]);

  useEffect(() => {
    const canvas = canvasRef.current!;
    const ctx = canvas.getContext("2d")!;
    let raf = 0;

    const frame = () => {
      raf = requestAnimationFrame(frame);
      const rect = canvas.getBoundingClientRect();
      const dpr = window.devicePixelRatio || 1;
      const W = Math.round(rect.width * dpr);
      const H = Math.round(rect.height * dpr);
      if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      if (!enabled || !comments.length) { stateRef.current.active = []; return; }

      const fs = Math.max(18, Math.round(canvas.height / 22));
      ctx.font = `${fs}px "Microsoft YaHei", sans-serif`;
      const laneH = Math.round(fs * 1.4);
      const numLanes = Math.max(1, Math.floor(canvas.height / laneH));

      const st = stateRef.current;
      const ts = timeSync.current;
      const t = ts.paused ? ts.base : ts.base + (performance.now() - ts.stamp) / 1000;

      // seek 检测:大跳则清屏并重定位游标
      if (t < st.lastT - 0.5 || t > st.lastT + 3) {
        st.active = [];
        let i = 0;
        while (i < comments.length && comments[i].time < t) i++;
        st.cursor = i;
      }
      st.lastT = t;

      // 生成到当前时间
      while (st.cursor < comments.length && comments[st.cursor].time <= t) {
        const c = comments[st.cursor++];
        if (!c.text) continue;
        const width = ctx.measureText(c.text).width;
        const color = `#${(c.color & 0xffffff).toString(16).padStart(6, "0")}`;
        const speed = (canvas.width + width) / DURATION;
        let lane = 0;
        if (c.mode === 4 || c.mode === 5) {
          const used = new Set(st.active.filter((a) => a.mode === c.mode).map((a) => a.lane));
          while (used.has(lane) && lane < numLanes - 1) lane++;
        } else {
          // 滚动:选入口已空出的道,否则选最快空出的
          let best = 0, bestFree = Infinity;
          for (let l = 0; l < numLanes; l++) {
            const last = st.active.filter((a) => a.mode !== 4 && a.mode !== 5 && a.lane === l).slice(-1)[0];
            const freeAt = last ? last.born + (last.width + fs) / last.speed : -1;
            if (t >= freeAt) { best = l; bestFree = -1; break; }
            if (freeAt < bestFree) { bestFree = freeAt; best = l; }
          }
          lane = best;
        }
        st.active.push({ text: c.text, color, mode: c.mode, born: t, width, lane, speed });
      }

      // 渲染 + 清理过期
      ctx.textBaseline = "top";
      ctx.lineWidth = Math.max(2, fs / 12);
      ctx.strokeStyle = "rgba(0,0,0,0.75)";
      st.active = st.active.filter((a) => {
        let x: number, y: number;
        if (a.mode === 4) {
          x = (canvas.width - a.width) / 2;
          y = canvas.height - (a.lane + 1) * laneH;
          if (t - a.born > FIXED_DUR) return false;
        } else if (a.mode === 5) {
          x = (canvas.width - a.width) / 2;
          y = a.lane * laneH;
          if (t - a.born > FIXED_DUR) return false;
        } else {
          x = canvas.width - (t - a.born) * a.speed;
          y = a.lane * laneH;
          if (x + a.width < 0) return false;
        }
        ctx.strokeText(a.text, x, y);
        ctx.fillStyle = a.color;
        ctx.fillText(a.text, x, y);
        return true;
      });
    };

    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, [comments, enabled, timeSync]);

  return <canvas ref={canvasRef} className="danmaku-canvas" />;
}
