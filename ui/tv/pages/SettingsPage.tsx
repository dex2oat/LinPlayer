import { useCallback, useEffect, useState } from "react";
import {
  cacheSize,
  checkUpdate,
  clearCache,
  dataPaths,
  fmtSize,
  getCrossServerResume,
  getPlaybackPrefs,
  getPrefs,
  getUpdateSettings,
  setCrossServerResume,
  setPlaybackPrefs,
  setPrefs,
  setUpdateSettings,
  type DataPaths,
  type PlaybackPrefs,
  type Prefs,
  type UpdateChannel,
  type UpdateSettings,
} from "@shared/api";
import type { Route } from "../App";
import { Icon, type IconName } from "../app/icons";
import { onTvKey } from "../app/focus";
import { FocusBoundary, FocusColumn, FocusItem } from "../components/Focus";

/** 设置(草稿 13)。左栏分类 + 右栏设置项的 Master-Detail。

    ★ **不做二级子页**。遥控器每深一层就多两次按键(进 + 出),TV 上层级深度就是体验成本。
      复杂的项一律在右栏内用分组标题分段,一层到底。
    ★ **只画后端真有命令的项**。草稿里的「画质增强 / 弹幕 / 网络与代理」这三个分类
      这一版没画:超分档位是**跟着当前播放**的运行时开关(不落盘,见 setShaderLevel),
      离开播放页设它没有意义;弹幕渲染参数和代理主机端口都要文本输入 + 核层暂无对应的
      TV 侧简化命令。**做不到的开关一个都不画** —— 画了就是骗自己也骗评审。
    ★ 左右两栏是两个独立的焦点容器,靠焦点库的方向判定天然互通(左栏按右进右栏,反之亦然),
      不需要自己接线。 */

type Cat = "general" | "player" | "track" | "storage" | "about";

const CATS: { id: Cat; label: string; icon: IconName }[] = [
  { id: "general", label: "通用", icon: "settings" },
  { id: "player", label: "播放器", icon: "play" },
  { id: "track", label: "字幕与音轨", icon: "sub" },
  { id: "storage", label: "存储与缓存", icon: "download" },
  { id: "about", label: "关于与更新", icon: "info" },
];

/** 语言偏好的取值。核层收的是 Emby 的三字母语言码,"" = 自动(不指定)。 */
const LANGS: Choice[] = [
  { label: "自动", value: "" },
  { label: "中文", value: "chi" },
  { label: "日语", value: "jpn" },
  { label: "英语", value: "eng" },
];

const SPEEDS: Choice[] = [
  { label: "0.75x", value: "0.75" },
  { label: "1.0x", value: "1" },
  { label: "1.25x", value: "1.25" },
  { label: "1.5x", value: "1.5" },
  { label: "2.0x", value: "2" },
];

type Choice = { label: string; value: string };
type Picker = {
  title: string;
  opts: Choice[];
  cur: string;
  onPick: (v: string) => void;
};

export default function SettingsPage(_props: { go: (r: Route) => void }) {
  const [cat, setCat] = useState<Cat>("general");
  const [picker, setPicker] = useState<Picker | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  /* ★ 每组各自加载,**不要 Promise.all 屏障**。等齐再渲染 = 机顶盒上整屏白到像死机。 */
  const [cross, setCross] = useState<boolean | null>(null);
  const [pb, setPb] = useState<PlaybackPrefs | null>(null);
  const [prefs, setPrefsState] = useState<Prefs | null>(null);
  const [upd, setUpd] = useState<UpdateSettings | null>(null);
  const [cache, setCache] = useState<number | null>(null);
  const [paths, setPaths] = useState<DataPaths | null>(null);

  useEffect(() => {
    getCrossServerResume().then(setCross).catch(() => {});
    getPlaybackPrefs().then(setPb).catch(() => {});
    getPrefs().then(setPrefsState).catch(() => {});
    getUpdateSettings().then(setUpd).catch(() => {});
    cacheSize().then(setCache).catch(() => {});
    dataPaths().then(setPaths).catch(() => {});
  }, []);

  const say = useCallback((m: string) => {
    setToast(m);
    setTimeout(() => setToast(null), 3000);
  }, []);

  /* 返回键先收面板。设置页是导航轨上的顶层页,栈里只有它自己,
     所以 App 那边的返回是空操作,两边不会打架。 */
  useEffect(() => onTvKey((k) => k === "back" && setPicker(null)), []);

  /* 写回一律「先本地改、再发命令」:核层报错就把话原样吐出来,不静默吞掉
     (静默吞的表现是开关拨过去了、下次进页又弹回来,而且没人知道为什么)。 */
  const savePb = (patch: Partial<PlaybackPrefs>) => {
    if (!pb) return;
    const next = { ...pb, ...patch };
    setPb(next);
    setPlaybackPrefs(next).catch((e) => {
      setPb(pb);
      say(String(e));
    });
  };

  const saveTrack = (patch: Partial<Prefs>) => {
    if (!prefs) return;
    const next = { ...prefs, ...patch };
    setPrefsState(next);
    setPrefs({
      audio_lang: next.audio_lang,
      sub_lang: next.sub_lang,
      sub_enabled: next.sub_enabled,
    }).catch((e) => {
      setPrefsState(prefs);
      say(String(e));
    });
  };

  const saveUpd = (channel: UpdateChannel, autoCheck: boolean) => {
    if (!upd) return;
    const prev = upd;
    setUpd({ ...upd, channel, auto_check: autoCheck });
    setUpdateSettings(channel, autoCheck).catch((e) => {
      setUpd(prev);
      say(String(e));
    });
  };

  return (
    <>
      <div style={{ display: "flex", height: "100%" }}>
        <div className="master">
          <FocusColumn focusKey="SET_CATS">
            <div className="ptitle" style={{ fontSize: 34, marginBottom: 26 }}>
              设置
            </div>
            {CATS.map((c, i) => (
              <FocusItem
                key={c.id}
                className={`mitem${cat === c.id ? " on" : ""}`}
                autoFocus={i === 0}
                onEnter={() => setCat(c.id)}
              >
                <Icon n={c.icon} className="ic ic-btn" />
                {c.label}
              </FocusItem>
            ))}
          </FocusColumn>
        </div>

        <div className="detail" style={{ minWidth: 0 }}>
          {/* 分类切换时右栏整体重挂(key),否则上一类的最后焦点会被记到新一类的同序号行上。 */}
          <FocusColumn key={cat} focusKey="SET_ROWS">
            {cat === "general" && (
              <>
                <Grp>播放行为</Grp>
                {cross != null && (
                  <SwRow
                    t="跨服务器续播"
                    d="同一部片在别的服务器上看过也接着播"
                    on={cross}
                    onToggle={() => {
                      const v = !cross;
                      setCross(v);
                      setCrossServerResume(v).catch((e) => {
                        setCross(!v);
                        say(String(e));
                      });
                    }}
                  />
                )}
                {pb && (
                  <>
                    <SwRow
                      t="跳过片头"
                      d="服务端有章节标记时自动跳过"
                      on={pb.skip_intro}
                      onToggle={() => savePb({ skip_intro: !pb.skip_intro })}
                    />
                    <SwRow
                      t="跳过片尾"
                      d="片尾后面还有内容时才跳"
                      on={pb.skip_outro}
                      onToggle={() => savePb({ skip_outro: !pb.skip_outro })}
                    />
                  </>
                )}
              </>
            )}

            {cat === "player" &&
              (pb ? (
                <>
                  <Grp>解码</Grp>
                  <SwRow
                    t="硬件解码"
                    d="关闭后走软解,弱机可能卡顿"
                    on={pb.hwdec === "auto-safe"}
                    onToggle={() =>
                      savePb({ hwdec: pb.hwdec === "auto-safe" ? "no" : "auto-safe" })
                    }
                  />
                  <SwRow
                    t="杜比视界自动软解"
                    d="检测到 DV 片源时自动切 gpu-next"
                    on={pb.dolby_auto_sw}
                    onToggle={() => savePb({ dolby_auto_sw: !pb.dolby_auto_sw })}
                  />

                  <Grp>播放</Grp>
                  <ValRow
                    t="默认倍速"
                    val={`${pb.default_speed}x`}
                    onEnter={() =>
                      setPicker({
                        title: "默认倍速",
                        opts: SPEEDS,
                        cur: String(pb.default_speed),
                        onPick: (v) => savePb({ default_speed: Number(v) }),
                      })
                    }
                  />
                  <SwRow
                    t="进度条预览缩略图"
                    d="拖动进度条时显示画面预览,服务端没刮章节则不生效"
                    on={pb.preview_thumbs}
                    onToggle={() => savePb({ preview_thumbs: !pb.preview_thumbs })}
                  />
                </>
              ) : (
                <Loading />
              ))}

            {cat === "track" &&
              (prefs ? (
                <>
                  <Grp>字幕</Grp>
                  <SwRow
                    t="默认开启字幕"
                    on={prefs.sub_enabled}
                    onToggle={() => saveTrack({ sub_enabled: !prefs.sub_enabled })}
                  />
                  <ValRow
                    t="字幕语言"
                    d="起播时优先选这个语言的字幕轨"
                    val={labelOf(LANGS, prefs.sub_lang ?? "")}
                    onEnter={() =>
                      setPicker({
                        title: "字幕语言",
                        opts: LANGS,
                        cur: prefs.sub_lang ?? "",
                        onPick: (v) => saveTrack({ sub_lang: v || null }),
                      })
                    }
                  />

                  <Grp>音轨</Grp>
                  <ValRow
                    t="音轨语言"
                    d="起播时优先选这个语言的音轨"
                    val={labelOf(LANGS, prefs.audio_lang ?? "")}
                    onEnter={() =>
                      setPicker({
                        title: "音轨语言",
                        opts: LANGS,
                        cur: prefs.audio_lang ?? "",
                        onPick: (v) => saveTrack({ audio_lang: v || null }),
                      })
                    }
                  />
                </>
              ) : (
                <Loading />
              ))}

            {cat === "storage" && (
              <>
                <Grp>缓存</Grp>
                <ValRow
                  t="清空缓存"
                  d="只删缓存,不动账号 / 观看记录 / 下载"
                  val={cache == null ? "统计中…" : fmtSize(cache) || "0 B"}
                  onEnter={() => {
                    clearCache()
                      .then(() => {
                        say("缓存已清空");
                        return cacheSize().then(setCache);
                      })
                      .catch((e) => say(String(e)));
                  }}
                />

                <Grp>数据目录</Grp>
                {/* 只读信息行:软件把东西放哪了,得让用户看得见(取日志时要用)。 */}
                <div className="srow">
                  <div className="tx">
                    <div className="t">数据根目录</div>
                    <div className="d">{paths?.root ?? "…"}</div>
                  </div>
                </div>
              </>
            )}

            {cat === "about" &&
              (upd ? (
                <>
                  <Grp>版本</Grp>
                  <div className="srow">
                    <div className="tx">
                      <div className="t">当前版本</div>
                    </div>
                    <div className="val">{upd.current_version}</div>
                  </div>

                  <Grp>更新</Grp>
                  <ValRow
                    t="更新渠道"
                    d="预览版更早拿到新功能,也更容易遇到问题"
                    val={upd.channel === "prerelease" ? "预览版" : "正式版"}
                    onEnter={() =>
                      setPicker({
                        title: "更新渠道",
                        opts: [
                          { label: "正式版", value: "stable" },
                          { label: "预览版", value: "prerelease" },
                        ],
                        cur: upd.channel,
                        onPick: (v) => saveUpd(v as UpdateChannel, upd.auto_check),
                      })
                    }
                  />
                  <SwRow
                    t="自动检查更新"
                    on={upd.auto_check}
                    onToggle={() => saveUpd(upd.channel, !upd.auto_check)}
                  />
                  <ValRow
                    t="立即检查更新"
                    val="›"
                    onEnter={() => {
                      say("检查中…");
                      checkUpdate()
                        /* null = 确实已是最新;抛错 = 没查成(断网/限流)。两者别混。 */
                        .then((info) =>
                          say(info ? `有新版本 ${info.version}` : "已经是最新版本"),
                        )
                        .catch((e) => say(`检查失败:${e}`));
                    }}
                  />
                </>
              ) : (
                <Loading />
              ))}
          </FocusColumn>
        </div>
      </div>

      {picker && (
        <FocusBoundary className="panel" focusKey="SET_PICK" onBack={() => setPicker(null)}>
          <div className="ph">{picker.title}</div>
          <div className="scroll">
            {picker.opts.map((o) => (
              <FocusItem
                key={o.value}
                className={`pitem${o.value === picker.cur ? " on" : ""}`}
                autoFocus={o.value === picker.cur}
                onEnter={() => {
                  picker.onPick(o.value);
                  setPicker(null);
                }}
              >
                {o.label}
              </FocusItem>
            ))}
          </div>
        </FocusBoundary>
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/* ------------------------------------------------------------ */

function Grp({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontSize: 16,
        letterSpacing: ".14em",
        color: "var(--tv-ink-3)",
        fontWeight: 640,
        margin: "30px 0 8px",
      }}
    >
      {children}
    </div>
  );
}

/** 开关行。★ **整行**可聚焦,确认键直接切换 —— 不要求焦点落到开关本身。
 *  让开关自己当焦点目标等于每行多一格焦点位,而这一行只有一个动作。 */
function SwRow({
  t,
  d,
  on,
  onToggle,
}: {
  t: string;
  d?: string;
  on: boolean;
  onToggle: () => void;
}) {
  return (
    <FocusItem className="srow" onEnter={onToggle}>
      <div className="tx">
        <div className="t">{t}</div>
        {d && <div className="d">{d}</div>}
      </div>
      <div className={`sw${on ? " on" : ""}`} style={{ marginLeft: "auto" }}>
        <i />
      </div>
    </FocusItem>
  );
}

/** 带取值的行。确认键 → 右侧面板选值,**不做内联展开** ——
 *  内联展开会把下面所有行顶下去,焦点位置整个错乱。 */
function ValRow({
  t,
  d,
  val,
  onEnter,
}: {
  t: string;
  d?: string;
  val: string;
  onEnter: () => void;
}) {
  return (
    <FocusItem className="srow" onEnter={onEnter}>
      <div className="tx">
        <div className="t">{t}</div>
        {d && <div className="d">{d}</div>}
      </div>
      <div className="val">{val} ›</div>
    </FocusItem>
  );
}

function Loading() {
  return <div className="psub" style={{ marginTop: 20 }}>载入中…</div>;
}

function labelOf(opts: Choice[], v: string): string {
  return opts.find((o) => o.value === v)?.label ?? v;
}
