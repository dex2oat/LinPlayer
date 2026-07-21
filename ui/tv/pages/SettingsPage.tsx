import { useCallback, useEffect, useRef, useState } from "react";
import { pause, resume } from "@noriginmedia/norigin-spatial-navigation";
import {
  bangumiAccount,
  bangumiAuthorizeUrl,
  bangumiExchange,
  bangumiLoginToken,
  bangumiLogout,
  cacheSize,
  checkUpdate,
  clearCache,
  dataPaths,
  fmtSize,
  getCrossServerResume,
  getPlaybackPrefs,
  getPrefs,
  getProxy,
  getUpdateSettings,
  setCrossServerResume,
  setDetailBlur,
  setPlaybackPrefs,
  setPrefs,
  setProxy,
  setUpdateSettings,
  traktAccount,
  traktDeviceCode,
  traktLogout,
  traktPoll,
  type DataPaths,
  type PlaybackPrefs,
  type Prefs,
  type ProxyConfig,
  type SyncAccount,
  type TraktDeviceCode,
  type UpdateChannel,
  type UpdateSettings,
} from "@shared/api";
import { useTheme } from "@shared/theme";
import type { Route } from "../App";
import { Icon, type IconName } from "../app/icons";
import { onTvKey } from "../app/focus";
import { FocusBoundary, FocusColumn, FocusItem } from "../components/Focus";

/** 设置(草稿 13)。左栏分类 + 右栏设置项的 Master-Detail。

    ★ **不做二级子页**。遥控器每深一层就多两次按键(进 + 出),TV 上层级深度就是体验成本。
      复杂的项一律在右栏内用分组标题分段,一层到底。
    ★ **只画后端真有命令的项**。**做不到的开关一个都不画** —— 画了就是骗自己也骗评审。
      按这条,现在画着的每一项背后都有一条**在 apps/android 的 generate_handler! 里
      真注册过**的命令(逐个核对过,2026-07-21):
        外观 → set_detail_blur;主题走 @shared/theme 的 localStorage(不需要后端),
               且 tv.css 里真有 [data-theme="light"] 分支 —— 拨过去屏幕真的变
        网络 → get_proxy / set_proxy
        账号 → trakt_account / trakt_device_code / trakt_poll / trakt_disconnect
               bangumi_account / bangumi_authorize_url / bangumi_exchange_code /
               bangumi_login_token / bangumi_disconnect
      仍然**没画**的:画质增强(超分档位是跟着当前播放的运行时开关,不落盘,
      见 setShaderLevel,离开播放页设它没有意义)、弹幕渲染参数(核层只管拉取和过滤,
      渲染参数在播放页那一侧,设置页设不了)。
    ★ 左右两栏是两个独立的焦点容器,靠焦点库的方向判定天然互通(左栏按右进右栏,反之亦然),
      不需要自己接线。 */

type Cat =
  | "general"
  | "appearance"
  | "player"
  | "track"
  | "network"
  | "account"
  | "storage"
  | "about";

const CATS: { id: Cat; label: string; icon: IconName }[] = [
  { id: "general", label: "通用", icon: "settings" },
  { id: "appearance", label: "外观", icon: "info" },
  { id: "player", label: "播放器", icon: "play" },
  { id: "track", label: "字幕与音轨", icon: "sub" },
  { id: "network", label: "网络", icon: "refresh" },
  { id: "account", label: "账号", icon: "heart" },
  { id: "storage", label: "存储与缓存", icon: "download" },
  { id: "about", label: "关于与更新", icon: "info" },
];

/** 语言偏好的取值。核层收的是 Emby 的三字母语言码(ISO 639-2/B),"" = 自动(不指定)。
 *  ★ 原来只有中/日/英三项 —— 片源里最常见的粤语、韩语、以及欧洲语系一个都选不了,
 *    而核层对这个字段只是原样透给 Emby,并没有"只认这四个"的限制。 */
const LANGS: Choice[] = [
  { label: "自动", value: "" },
  { label: "中文", value: "chi" },
  { label: "粤语", value: "yue" },
  { label: "日语", value: "jpn" },
  { label: "英语", value: "eng" },
  { label: "韩语", value: "kor" },
  { label: "法语", value: "fre" },
  { label: "德语", value: "ger" },
  { label: "西班牙语", value: "spa" },
  { label: "葡萄牙语", value: "por" },
  { label: "意大利语", value: "ita" },
  { label: "俄语", value: "rus" },
  { label: "泰语", value: "tha" },
  { label: "越南语", value: "vie" },
  { label: "印尼语", value: "ind" },
  { label: "阿拉伯语", value: "ara" },
  { label: "印地语", value: "hin" },
];

/** ★ 后端 default_speed 是个裸 f64,支持 0.25~4.0;原来这里只给 5 档,
 *  0.5x(听不清时逐句抠)和 3x/4x(过片头)完全够不着。 */
const SPEEDS: Choice[] = [
  "0.25",
  "0.5",
  "0.75",
  "1",
  "1.25",
  "1.5",
  "1.75",
  "2",
  "2.5",
  "3",
  "3.5",
  "4",
].map((v) => ({ label: `${v}x`, value: v }));

/** 代理类型。取值必须和 core/config.rs 的 ProxyConfig.type_ 逐字一致。 */
const PROXY_TYPES: Choice[] = [
  { label: "不使用", value: "none" },
  { label: "HTTP", value: "http" },
  { label: "HTTPS", value: "https" },
  { label: "SOCKS5", value: "socks5" },
  { label: "SOCKS4", value: "socks4" },
];

/** 个人 Access Token 的自助生成页 —— 说明文字里直接把地址给出来,
 *  电视上没有"点一下打开浏览器"这回事,用户是拿手机去开的。 */
const BGM_TOKEN_PAGE = "next.bgm.tv/demo/access-token";

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
  const [proxy, setProxyState] = useState<ProxyConfig | null>(null);
  /* undefined = 还没问到(不能当"没连"画,否则每次进页面都闪一下「未连接」)。 */
  const [trakt, setTrakt] = useState<SyncAccount | null | undefined>(undefined);
  const [bgm, setBgm] = useState<SyncAccount | null | undefined>(undefined);
  const [tcode, setTcode] = useState<TraktDeviceCode | null>(null);
  /* Bangumi 授权链接。★ 不能用 toast 显示:那是条几十上百字符的 URL,
     3 秒就没了,用户拿手机根本抄不完。要常驻在行下面。 */
  const [bgmUrl, setBgmUrl] = useState<string | null>(null);

  const { theme, setTheme } = useTheme();

  useEffect(() => {
    getCrossServerResume().then(setCross).catch(() => {});
    getPlaybackPrefs().then(setPb).catch(() => {});
    getPrefs().then(setPrefsState).catch(() => {});
    getUpdateSettings().then(setUpd).catch(() => {});
    cacheSize().then(setCache).catch(() => {});
    dataPaths().then(setPaths).catch(() => {});
    getProxy().then(setProxyState).catch(() => {});
    traktAccount().then(setTrakt).catch(() => setTrakt(null));
    bangumiAccount().then(setBgm).catch(() => setBgm(null));
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

  /** 详情页背景模糊。**单独的命令**(set_detail_blur),不能混进 setPrefs ——
   *  那个只收选轨三项,拼一个完整 Prefs 扔过去反而会把别的偏好带回旧值。 */
  const saveBlur = (v: number) => {
    if (!prefs) return;
    const n = Math.max(0, Math.min(100, v));
    const prev = prefs;
    setPrefsState({ ...prefs, detail_blur: n });
    setDetailBlur(n).catch((e) => {
      setPrefsState(prev);
      say(String(e));
    });
  };

  const saveProxy = (patch: Partial<ProxyConfig>) => {
    if (!proxy) return;
    const prev = proxy;
    const next = { ...proxy, ...patch };
    setProxyState(next);
    setProxy(next).catch((e) => {
      setProxyState(prev);
      say(String(e));
    });
  };

  /* ---- Trakt 设备码流 ----
     取码 → 用户拿手机去 verification_url 输 user_code → 这里按 interval 轮询。
     ★ 轮询间隔必须**听服务端的**(interval 秒),自己拍一个更短的会被 Trakt 限流,
       表现是"码是对的但一直连不上"。 */
  useEffect(() => {
    if (!tcode) return;
    let alive = true;
    const deadline = Date.now() + tcode.expires_in * 1000;
    const t = setInterval(async () => {
      if (!alive) return;
      if (Date.now() > deadline) {
        setTcode(null);
        say("授权码已过期,请重新连接");
        return;
      }
      try {
        const r = await traktPoll(tcode.device_code);
        if (!alive) return;
        if (r.account) {
          setTrakt(r.account);
          setTcode(null);
          say("Trakt 已连接");
        }
      } catch {
        /* pending 期间核层会正常返回 status=pending;这里进 catch 说明是网络抖动,
           别把面板关掉 —— 下一拍再试就是了。 */
      }
    }, Math.max(1, tcode.interval) * 1000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [tcode, say]);

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

            {cat === "appearance" && (
              <>
                <Grp>主题</Grp>
                <ValRow
                  t="界面主题"
                  d="浅色适合白天亮房间;客厅暗光下深色更省眼"
                  val={theme === "light" ? "浅色" : "深色"}
                  onEnter={() =>
                    setPicker({
                      title: "界面主题",
                      opts: [
                        { label: "深色", value: "dark" },
                        { label: "浅色", value: "light" },
                      ],
                      cur: theme,
                      onPick: (v) => setTheme(v === "light" ? "light" : "dark"),
                    })
                  }
                />

                <Grp>详情页</Grp>
                {prefs ? (
                  <StepRow
                    t="背景模糊"
                    d="左右键 ±10。糊得越狠,压在背景图上的标题和简介越好读"
                    val={`${prefs.detail_blur}`}
                    onStep={(d) => saveBlur(prefs.detail_blur + d)}
                  />
                ) : (
                  <Loading />
                )}
              </>
            )}

            {cat === "network" &&
              (proxy ? (
                <>
                  <Grp>代理</Grp>
                  <ValRow
                    t="代理类型"
                    d="选「不使用」即关闭代理,下面几项就不再生效"
                    val={labelOf(PROXY_TYPES, proxy.type)}
                    onEnter={() =>
                      setPicker({
                        title: "代理类型",
                        opts: PROXY_TYPES,
                        cur: proxy.type,
                        onPick: (v) => saveProxy({ type: v }),
                      })
                    }
                  />
                  {proxy.type !== "none" && (
                    <>
                      <TextRow
                        t="服务器地址"
                        d="主机名或 IP,不带 http:// 前缀"
                        val={proxy.host}
                        placeholder="127.0.0.1"
                        onCommit={(v) => saveProxy({ host: v.trim() })}
                      />
                      <TextRow
                        t="端口"
                        val={proxy.port ? String(proxy.port) : ""}
                        placeholder="7890"
                        numeric
                        /* 非数字/越界一律当 0 存回去 —— 核层的 is_enabled() 要求 port>0,
                           存 0 等于"这条代理还没配好",比存一个假端口诚实。 */
                        onCommit={(v) => saveProxy({ port: clampPort(v) })}
                      />
                      <TextRow
                        t="用户名"
                        d="不需要认证就留空"
                        val={proxy.username}
                        onCommit={(v) => saveProxy({ username: v })}
                      />
                      <TextRow
                        t="密码"
                        val={proxy.password}
                        secret
                        onCommit={(v) => saveProxy({ password: v })}
                      />
                      <SwRow
                        t="播放流也走代理"
                        d="关掉则只有接口请求走代理,视频直连(仅 HTTP 系代理有效)"
                        on={proxy.proxy_media}
                        onToggle={() => saveProxy({ proxy_media: !proxy.proxy_media })}
                      />
                    </>
                  )}
                </>
              ) : (
                <Loading />
              ))}

            {cat === "account" && (
              <>
                <Grp>Trakt</Grp>
                {trakt === undefined ? (
                  <Loading />
                ) : trakt ? (
                  <ValRow
                    t="断开 Trakt"
                    d={`已连接${trakt.username ? `:${trakt.username}` : ""}`}
                    val="断开 ›"
                    onEnter={() => {
                      traktLogout()
                        .then(() => {
                          setTrakt(null);
                          say("已断开 Trakt");
                        })
                        .catch((e) => say(String(e)));
                    }}
                  />
                ) : (
                  <ValRow
                    t="连接 Trakt"
                    d="用手机打开网址输入配对码,电视上不用打字"
                    val="连接 ›"
                    onEnter={() => {
                      say("正在取配对码…");
                      traktDeviceCode()
                        .then(setTcode)
                        .catch((e) => say(String(e)));
                    }}
                  />
                )}
                {tcode && (
                  <div className="srow" style={{ height: "auto", padding: "18px 20px" }}>
                    <div className="tx">
                      <div className="t">在手机上打开 {tcode.verification_url}</div>
                      <div className="d" style={{ fontSize: 30, letterSpacing: ".2em", marginTop: 8 }}>
                        {tcode.user_code}
                      </div>
                      <div className="d" style={{ marginTop: 8 }}>输入后本页会自动完成,不用再操作</div>
                    </div>
                  </div>
                )}

                <Grp>Bangumi</Grp>
                {bgm === undefined ? (
                  <Loading />
                ) : bgm ? (
                  <ValRow
                    t="断开 Bangumi"
                    d={`已连接${bgm.username ? `:${bgm.username}` : ""}`}
                    val="断开 ›"
                    onEnter={() => {
                      bangumiLogout()
                        .then(() => {
                          setBgm(null);
                          say("已断开 Bangumi");
                        })
                        .catch((e) => say(String(e)));
                    }}
                  />
                ) : (
                  <>
                    {/* ★ 主推 Access Token:授权码有 30+ 个字符且区分大小写,
                        用遥控器在软键盘上敲完一次要好几分钟。个人令牌可以在手机上
                        生成好、用蓝牙键盘/手机输入法投过来,粘一次就完事。 */}
                    <TextRow
                      t="粘贴 Access Token(推荐)"
                      d={`在 ${BGM_TOKEN_PAGE} 自助生成,有效期最长一年`}
                      val=""
                      placeholder="粘贴令牌后按确认"
                      secret
                      clearOnCommit
                      onCommit={(v) => {
                        const tok = v.trim();
                        if (!tok) return;
                        say("正在登录…");
                        bangumiLoginToken(tok)
                          .then((a) => {
                            setBgm(a);
                            say("Bangumi 已连接");
                          })
                          .catch((e) => say(String(e)));
                      }}
                    />
                    <ValRow
                      t="获取授权链接"
                      d="另一种方式:在手机上打开链接授权,把回调里的 code 抄到下一行"
                      val={bgmUrl ? "已显示" : "显示 ›"}
                      onEnter={() => {
                        bangumiAuthorizeUrl()
                          .then(setBgmUrl)
                          .catch((e) => say(String(e)));
                      }}
                    />
                    {bgmUrl && (
                      <div className="srow" style={{ height: "auto", padding: "18px 20px" }}>
                        <div className="tx" style={{ minWidth: 0 }}>
                          <div className="d" style={{ overflowWrap: "anywhere", fontSize: 17 }}>
                            {bgmUrl}
                          </div>
                        </div>
                      </div>
                    )}
                    <TextRow
                      t="输入授权码"
                      val=""
                      placeholder="回调地址里的 code="
                      clearOnCommit
                      onCommit={(v) => {
                        const code = v.trim();
                        if (!code) return;
                        say("正在换取令牌…");
                        bangumiExchange(code)
                          .then((a) => {
                            setBgm(a);
                            say("Bangumi 已连接");
                          })
                          .catch((e) => say(String(e)));
                      }}
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

/** 数值调节行:聚焦后**左右键 ±10**,不做滑块。
 *
 *  ★ 滑块是鼠标控件 —— 遥控器上没有"拖"这个动作,做成滑块只能靠左右键假装拖,
 *    还得自己算命中区。直接把左右键当加减用,少一层翻译。
 *  ★ 抢左右键的写法照抄播放页的进度条(ProgressBar):FocusItem 拿不到方向键,
 *    只能自己在 window 上捕获,且**只在本行聚焦时**挂 —— 常挂会把整页的左右导航吃掉。 */
function StepRow({
  t,
  d,
  val,
  step = 10,
  onStep,
}: {
  t: string;
  d?: string;
  val: string;
  step?: number;
  onStep: (delta: number) => void;
}) {
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!focused) return;
    const h = (e: KeyboardEvent) => {
      if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
      e.stopPropagation();
      onStep(e.key === "ArrowRight" ? step : -step);
    };
    window.addEventListener("keydown", h, true);
    return () => window.removeEventListener("keydown", h, true);
  }, [focused, step, onStep]);

  return (
    <FocusItem
      className="srow"
      onFocus={() => setFocused(true)}
      /* 确认键无动作:值靠左右键改。给个空函数免得库把这一行当不可交互项。 */
      onEnter={() => {}}
    >
      <div className="tx">
        <div className="t">{t}</div>
        {d && <div className="d">{d}</div>}
      </div>
      <div className="val">‹ {val} ›</div>
    </FocusItem>
  );
}

/** 文本输入行。确认键把 DOM 焦点交给真 <input>,系统 IME 随之升起 ——
 *  写法与搜索页那个输入框一致(**不自建虚拟键盘**,理由见 SearchPage 顶部注释)。
 *
 *  ★ 输入期间必须 pause() 焦点库:IME 没接管的键会被库当成移动焦点,
 *    光标一动就跳出输入框。blur 时 resume()。
 *  ★ 提交时机是 **Enter 或失焦**,不是每次按键 —— 每敲一个字符就发一次 set_proxy
 *    会把半截主机名落盘,而且核层每次都要写文件。 */
function TextRow({
  t,
  d,
  val,
  placeholder,
  secret,
  numeric,
  clearOnCommit,
  onCommit,
}: {
  t: string;
  d?: string;
  val: string;
  placeholder?: string;
  /** 密码/令牌:显示成圆点。 */
  secret?: boolean;
  numeric?: boolean;
  /** 一次性输入(令牌/授权码):提交后清空,别把它留在屏幕上。 */
  clearOnCommit?: boolean;
  onCommit: (v: string) => void;
}) {
  const [v, setV] = useState(val);
  const ref = useRef<HTMLInputElement>(null);
  /* 外部值变了(保存失败回滚 / 首次加载完成)要跟上,但**正在输入时不要跟** ——
     否则用户打到一半会被写回旧值。用 document.activeElement 判是不是自己在输入。 */
  useEffect(() => {
    if (ref.current !== document.activeElement) setV(val);
  }, [val]);

  const commit = () => {
    onCommit(v);
    if (clearOnCommit) setV("");
  };

  return (
    <FocusItem className="srow" onEnter={() => ref.current?.focus()}>
      <div className="tx">
        <div className="t">{t}</div>
        {d && <div className="d">{d}</div>}
      </div>
      <input
        ref={ref}
        value={v}
        type={secret ? "password" : "text"}
        inputMode={numeric ? "numeric" : "text"}
        placeholder={placeholder}
        onChange={(e) => setV(e.target.value)}
        onFocus={() => pause()}
        onBlur={() => {
          resume();
          commit();
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter") ref.current?.blur(); // blur 里统一提交,别提交两次
          if (e.key === "Escape") {
            /* 输入中的返回 = 退出输入,不是退出本页。 */
            e.stopPropagation();
            setV(val);
            ref.current?.blur();
          }
        }}
        style={{
          marginLeft: "auto",
          width: 380,
          height: 56,
          borderRadius: 12,
          background: "rgba(255,255,255,.06)",
          border: "1px solid var(--tv-line)",
          padding: "0 16px",
          fontSize: 19,
          color: "var(--tv-ink)",
          fontFamily: "inherit", // 不能用 font:inherit 简写 —— 它会把上面的 fontSize 一起冲掉
          outline: "none",
        }}
      />
    </FocusItem>
  );
}

function Loading() {
  return <div className="psub" style={{ marginTop: 20 }}>载入中…</div>;
}

function labelOf(opts: Choice[], v: string): string {
  return opts.find((o) => o.value === v)?.label ?? v;
}

/** 端口:非数字/越界一律 0。核层 ProxyConfig.is_enabled() 要求 port>0,
 *  存 0 = "还没配好",比静默夹到 1 或 65535 诚实。 */
function clampPort(s: string): number {
  const n = Number(s.trim());
  return Number.isInteger(n) && n > 0 && n <= 65535 ? n : 0;
}
