import { useCallback, useEffect, useMemo, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  type MarketPlugin,
  type PluginInfo,
  type PluginPermissionInfo,
  type PluginSource,
  pluginDevPoll,
  pluginDisable,
  pluginEnable,
  pluginList,
  pluginMarketAddSource,
  pluginMarketInstall,
  pluginMarketList,
  pluginMarketRemoveSource,
  pluginMarketSources,
  pluginMarketToggleSource,
  pluginPanels,
  pluginPermissionCatalog,
  pluginPickDevDir,
  pluginPickInstall,
  pluginReload,
  pluginUninstall,
} from "@shared/api";
import {
  IconChevronRight,
  IconClose,
  IconPlugin,
  IconPlus,
  IconRefresh,
  IconSearch,
  IconShield,
  IconTrash,
} from "../app/icons";
import { Sw } from "../components/PluginView";
import { PluginSlot } from "../components/PluginHost";

/* ============================================================
   插件 —— 市场 + 已装 + 源订阅,一页三栏。
   ------------------------------------------------------------
   版式取舍(逐条来自 2026-07-23 的三份同类产品调研):
   · HACS:已装置顶、可装在下,不用让用户在两个页面之间来回找。这里做成
     顶部 tab 而不是两个入口 —— 因为「已装」经常是空的,空 tab 比空页面便宜。
   · Chrome 扩展:授权清单在**装/启用之前**弹,一行一条人话,不是一句
     「该插件需要若干权限」。词表由核层透出(见 pluginPermissionCatalog),
     前端抄一份的下场是加了新权限而弹窗里显示成光秃秃的 id。
   · Raycast:深色不靠阴影靠灰阶分层 —— 我们的 token 本来就是这套,
     卡片只用 --panel / --line,不加 box-shadow。
   · Kodi/Jellyfin/HACS **共同的两个洞**,这里补上:
       ① 第三方源没有任何信任标记 -> 卡片上打「第三方源」徽章
       ② 装完没人告诉用户「去哪用」 -> 启用后按贡献点给一句去处
   ============================================================ */

type Tab = "market" | "installed" | "sources";

type Toast = { kind: "ok" | "err"; text: string } | null;

type Pane = "settings" | "about" | "perm" | "log" | "ver";

const CATEGORIES: { id: string; label: string }[] = [
  { id: "", label: "全部" },
  { id: "source", label: "数据源" },
  { id: "ui", label: "界面" },
  { id: "player", label: "播放" },
  { id: "notify", label: "通知" },
  { id: "tools", label: "工具" },
];

/** 语义化版本比较。与核层 `registry_index::compare_versions` 同口径 —— 别用字典序,
 *  那会让 1.10.0 显得比 1.9.0 旧,「有更新」的角标就永远不亮。 */
function cmpVersion(a: string, b: string): number {
  const p = (s: string) =>
    (s.split(/[-+]/)[0] ?? "").split(".").map((x) => Number.parseInt(x, 10) || 0);
  const [x, y] = [p(a), p(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d !== 0) return d > 0 ? 1 : -1;
  }
  return 0;
}

/** 宿主能装的最新版。**必须取最大值而不是数组第一个** —— 本仓库在 GitHub Releases
 *  上栽过一模一样的跟头(返回顺序不可依赖),见 [release-version-monotonicity]。 */
function bestVersion(p: MarketPlugin, hostApi: number) {
  return p.versions
    .filter((v) => v.api_version === 0 || v.api_version <= hostApi)
    .reduce<MarketPlugin["versions"][number] | null>(
      (best, v) => (!best || cmpVersion(v.version, best.version) > 0 ? v : best),
      null,
    );
}

function initials(name: string) {
  return name.trim().slice(0, 2) || "?";
}

export default function PluginsPage() {
  const [tab, setTab] = useState<Tab>("market");
  const [q, setQ] = useState("");
  const [cat, setCat] = useState("");
  const [toast, setToast] = useState<Toast>(null);

  const [installed, setInstalled] = useState<PluginInfo[] | null>(null);
  const [market, setMarket] = useState<MarketPlugin[] | null>(null);
  const [marketErrors, setMarketErrors] = useState<{ source: string; error: string }[]>([]);
  const [hostApi, setHostApi] = useState(2);
  const [sources, setSources] = useState<PluginSource[]>([]);
  const [perms, setPerms] = useState<PluginPermissionInfo[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  /** 打开详情抽屉的插件(市场条目或已装条目)。 */
  const [detail, setDetail] = useState<{ market?: MarketPlugin; local?: PluginInfo } | null>(null);
  /** 待确认授权的插件 —— 确认后才真的启用。 */
  const [confirm, setConfirm] = useState<PluginInfo | null>(null);

  const ok = (text: string) => setToast({ kind: "ok", text });
  const err = (e: unknown) => setToast({ kind: "err", text: String(e) });
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 4200);
    return () => clearTimeout(t);
  }, [toast]);

  const loadInstalled = useCallback(
    () => pluginList().then(setInstalled).catch((e) => { setInstalled([]); err(e); }),
    [],
  );

  const loadMarket = useCallback(async (refresh: boolean) => {
    setRefreshing(true);
    try {
      const r = await pluginMarketList(refresh);
      setMarket(r.plugins);
      setMarketErrors(r.errors);
      setHostApi(r.apiVersion);
    } catch (e) {
      setMarket([]);
      err(e);
    } finally {
      setRefreshing(false);
    }
  }, []);

  /* 首屏三份数据各自渲染,不用 Promise.all 拦一道 —— 那会让最慢的一条
     决定整页什么时候出来(见 [perceived-slowness-is-animation])。 */
  useEffect(() => {
    loadInstalled();
    loadMarket(false);
    pluginMarketSources().then(setSources).catch(() => {});
    pluginPermissionCatalog().then(setPerms).catch(() => {});
  }, [loadInstalled, loadMarket]);

  /* 开发模式插件:文件改了就热重载。没有开发插件时后端直接返回 false,
     这条轮询几乎零成本;有的话省掉「改一行→手动点重载」的来回。 */
  useEffect(() => {
    const t = setInterval(() => {
      pluginDevPoll()
        .then((changed) => { if (changed) loadInstalled(); })
        .catch(() => {});
    }, 1500);
    return () => clearInterval(t);
  }, [loadInstalled]);

  const byId = useMemo(
    () => new Map((installed ?? []).map((p) => [p.id, p])),
    [installed],
  );

  const permById = useMemo(() => new Map(perms.map((p) => [p.id, p])), [perms]);

  const filteredMarket = useMemo(() => {
    const kw = q.trim().toLowerCase();
    return (market ?? []).filter((p) => {
      if (cat && (p.category ?? "tools") !== cat) return false;
      if (!kw) return true;
      return (
        p.name.toLowerCase().includes(kw) ||
        p.description.toLowerCase().includes(kw) ||
        p.author.toLowerCase().includes(kw) ||
        p.tags.some((t) => t.toLowerCase().includes(kw))
      );
    });
  }, [market, q, cat]);

  const filteredInstalled = useMemo(() => {
    const kw = q.trim().toLowerCase();
    return (installed ?? []).filter(
      (p) => !kw || p.name.toLowerCase().includes(kw) || p.id.toLowerCase().includes(kw),
    );
  }, [installed, q]);

  const updatable = useMemo(() => {
    const set = new Set<string>();
    for (const m of market ?? []) {
      const local = byId.get(m.id);
      const best = bestVersion(m, hostApi);
      if (local && best && cmpVersion(best.version, local.version) > 0) set.add(m.id);
    }
    return set;
  }, [market, byId, hostApi]);

  // ---------- 动作 ----------

  async function install(m: MarketPlugin) {
    setBusy(m.id);
    try {
      const r = await pluginMarketInstall(m.id);
      await loadInstalled();
      ok(
        `已安装 ${m.name} v${r.version}` +
          (r.verified ? "" : "(这个源没有提供校验和)") +
          " —— 默认停用,看过权限后再启用",
      );
    } catch (e) {
      err(e);
    } finally {
      setBusy(null);
    }
  }

  /** 启用前先摆权限。已经同意过的(status 不是 disabled 也没报权限错)照样再看一次 ——
   *  这一步很便宜,而「我什么时候同意的」是最常见的困惑。 */
  function requestEnable(p: PluginInfo) {
    if (p.permissions.length === 0) {
      void doEnable(p);
      return;
    }
    setConfirm(p);
  }

  async function doEnable(p: PluginInfo) {
    setConfirm(null);
    setBusy(p.id);
    try {
      await pluginEnable(p.id);
      await loadInstalled();
      ok(`已启用 ${p.name}${whereToUse(p)}`);
    } catch (e) {
      err(e);
    } finally {
      setBusy(null);
    }
  }

  async function disable(p: PluginInfo) {
    setBusy(p.id);
    try {
      await pluginDisable(p.id);
      await loadInstalled();
      ok(`已停用 ${p.name}`);
    } catch (e) {
      err(e);
    } finally {
      setBusy(null);
    }
  }

  async function remove(p: PluginInfo) {
    setBusy(p.id);
    try {
      await pluginUninstall(p.id);
      await loadInstalled();
      setDetail(null);
      ok(`已卸载 ${p.name}`);
    } catch (e) {
      err(e);
    } finally {
      setBusy(null);
    }
  }

  async function pickInstall() {
    setBusy("pick");
    try {
      const info = await pluginPickInstall();
      if (!info) return; // 用户取消
      await loadInstalled();
      setTab("installed");
      ok(`已安装 ${String(info.name ?? "")} —— 默认停用,看过权限后再启用`);
    } catch (e) {
      err(e);
    } finally {
      setBusy(null);
    }
  }

  async function pickDev() {
    setBusy("dev");
    try {
      const info = await pluginPickDevDir();
      if (!info) return;
      await loadInstalled();
      setTab("installed");
      ok(`已挂载开发插件 ${String(info.name ?? "")} —— 改完存盘会自动重载`);
    } catch (e) {
      err(e);
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <div className="cbar">
        <div className="crumb">
          <b>插件</b>
          <span className="count">
            {installed ? `已装 ${installed.length}` : ""}
          </span>
        </div>
        <div className="pg-tabs">
          {(
            [
              ["market", "发现"],
              ["installed", `已安装${installed?.length ? ` (${installed.length})` : ""}`],
              ["sources", "插件源"],
            ] as [Tab, string][]
          ).map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={"pg-tab" + (tab === id ? " on" : "")}
              onClick={() => setTab(id)}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="push">
          {tab !== "sources" && (
            <label className="searchbox">
              <IconSearch size={15} />
              <input
                value={q}
                onChange={(e) => setQ(e.target.value)}
                placeholder={tab === "market" ? "搜索插件" : "搜索已装插件"}
              />
            </label>
          )}
          {tab === "market" && (
            <button
              type="button"
              className="ibtn"
              title="刷新插件源"
              disabled={refreshing}
              onClick={() => loadMarket(true)}
            >
              <IconRefresh size={16} className={refreshing ? "spin" : undefined} />
            </button>
          )}
        </div>
      </div>

      <div className="cbody scroll">
        {tab === "market" && (
          <MarketTab
            plugins={filteredMarket}
            loading={market === null}
            errors={marketErrors}
            cat={cat}
            onCat={setCat}
            installedById={byId}
            updatable={updatable}
            hostApi={hostApi}
            busy={busy}
            onInstall={install}
            onOpen={(m) => setDetail({ market: m, local: byId.get(m.id) })}
            onGoSources={() => setTab("sources")}
          />
        )}

        {tab === "installed" && (
          <InstalledTab
            plugins={filteredInstalled}
            loading={installed === null}
            busy={busy}
            updatable={updatable}
            onEnable={requestEnable}
            onDisable={disable}
            onOpen={(p) =>
              setDetail({ local: p, market: (market ?? []).find((m) => m.id === p.id) })
            }
            onReload={(p) =>
              pluginReload(p.id).then(() => { loadInstalled(); ok(`已重载 ${p.name}`); }).catch(err)
            }
            onPickInstall={pickInstall}
            onPickDev={pickDev}
            onGoMarket={() => setTab("market")}
          />
        )}

        {tab === "sources" && (
          <SourcesTab
            sources={sources}
            onChange={(s) => { setSources(s); loadMarket(true); }}
            onError={err}
            onOk={ok}
          />
        )}
      </div>

      {detail && (
        <DetailDrawer
          market={detail.market}
          local={detail.local}
          hostApi={hostApi}
          permById={permById}
          busy={busy}
          onClose={() => setDetail(null)}
          onInstall={install}
          onEnable={requestEnable}
          onDisable={disable}
          onUninstall={remove}
        />
      )}

      {confirm && (
        <PermissionModal
          plugin={confirm}
          permById={permById}
          onCancel={() => setConfirm(null)}
          onAllow={() => doEnable(confirm)}
        />
      )}

      {toast && <div className={"pg-toast " + toast.kind}>{toast.text}</div>}
    </>
  );
}

/** 启用后一句「去哪用」。Kodi/Jellyfin/HACS 全都缺这一句,
 *  用户装完数据源插件在服务器列表里找不到它,只会以为插件坏了。 */
function whereToUse(p: PluginInfo): string {
  const c = p.contributes;
  if (c?.dataSources) return " —— 去「服务器 → 添加服务器」里选它";
  if (c?.panels) return " —— 面板会出现在首页/设置里";
  if (c?.actions) return " —— 操作按钮已挂上";
  return "";
}

/* ---------------- 发现 ---------------- */

function MarketTab({
  plugins, loading, errors, cat, onCat, installedById, updatable, hostApi,
  busy, onInstall, onOpen, onGoSources,
}: {
  plugins: MarketPlugin[];
  loading: boolean;
  errors: { source: string; error: string }[];
  cat: string;
  onCat: (c: string) => void;
  installedById: Map<string, PluginInfo>;
  updatable: Set<string>;
  hostApi: number;
  busy: string | null;
  onInstall: (m: MarketPlugin) => void;
  onOpen: (m: MarketPlugin) => void;
  onGoSources: () => void;
}) {
  return (
    <>
      <div className="pg-chips">
        {CATEGORIES.map((c) => (
          <button
            key={c.id}
            type="button"
            className={"pill" + (cat === c.id ? " on" : "")}
            onClick={() => onCat(c.id)}
          >
            {c.label}
          </button>
        ))}
      </div>

      {/* 一个源挂了不该让整个市场变成报错页 —— 挂掉的单独列出来,其余照常展示。 */}
      {errors.map((e) => (
        <div key={e.source} className="pg-warn">
          插件源「{e.source}」拉取失败:{e.error}
          <button type="button" className="btn sm" onClick={onGoSources}>
            管理插件源
          </button>
        </div>
      ))}

      {loading ? (
        <div className="pg-grid">
          {Array.from({ length: 6 }, (_, i) => (
            <div key={i} className="pg-card skel" />
          ))}
        </div>
      ) : plugins.length === 0 ? (
        <div className="pg-empty">
          <IconPlugin size={30} />
          <b>没有找到插件</b>
          <span>换个关键词或分类;也可能是插件源还没配好。</span>
          <button type="button" className="btn" onClick={onGoSources}>
            管理插件源
          </button>
        </div>
      ) : (
        <div className="pg-grid">
          {plugins.map((m) => {
            const local = installedById.get(m.id);
            const best = bestVersion(m, hostApi);
            return (
              <div key={m.id} className="pg-card" onClick={() => onOpen(m)}>
                <div className="ic">
                  {m.icon ? <img src={m.icon} alt="" /> : <span>{initials(m.name)}</span>}
                </div>
                <div className="bd">
                  <div className="nm">
                    {m.name}
                    {!m.from_builtin && (
                      <span className="pg-badge warn" title={`来自 ${m.source_name}`}>
                        第三方源
                      </span>
                    )}
                    {updatable.has(m.id) && <span className="pg-badge accent">可更新</span>}
                    {local && !updatable.has(m.id) && <span className="pg-badge good">已安装</span>}
                  </div>
                  <div className="ds">{m.description || "作者没有写介绍"}</div>
                  <div className="mt">
                    <span>{m.author || "未知作者"}</span>
                    {best && <span>v{best.version}</span>}
                    {m.permissions.length > 0 && (
                      <span>
                        <IconShield size={12} /> {m.permissions.length} 项权限
                      </span>
                    )}
                  </div>
                </div>
                <div className="ac" onClick={(e) => e.stopPropagation()}>
                  {!best ? (
                    <span className="pg-note">需更新应用</span>
                  ) : local && !updatable.has(m.id) ? (
                    <button type="button" className="btn sm" onClick={() => onOpen(m)}>
                      详情
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="btn sm primary"
                      disabled={busy === m.id}
                      onClick={() => onInstall(m)}
                    >
                      {busy === m.id ? "…" : local ? "更新" : "安装"}
                    </button>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}

/* ---------------- 已安装 ---------------- */

function InstalledTab({
  plugins, loading, busy, updatable, onEnable, onDisable, onOpen, onReload,
  onPickInstall, onPickDev, onGoMarket,
}: {
  plugins: PluginInfo[];
  loading: boolean;
  busy: string | null;
  updatable: Set<string>;
  onEnable: (p: PluginInfo) => void;
  onDisable: (p: PluginInfo) => void;
  onOpen: (p: PluginInfo) => void;
  onReload: (p: PluginInfo) => void;
  onPickInstall: () => void;
  onPickDev: () => void;
  onGoMarket: () => void;
}) {
  if (loading) return <div className="pg-empty"><span className="spinner" /></div>;

  return (
    <>
      {plugins.length === 0 ? (
        <div className="pg-empty">
          <IconPlugin size={30} />
          <b>还没有装插件</b>
          <span>去「发现」看看,或者直接装一个本地 .ipk 包。</span>
          <div className="pg-empty-ac">
            <button type="button" className="btn primary" onClick={onGoMarket}>浏览插件市场</button>
            <button type="button" className="btn" onClick={onPickInstall}>安装本地包…</button>
          </div>
        </div>
      ) : (
        <div className="pg-rows">
          {plugins.map((p) => (
            <div key={p.id} className={"pg-row" + (p.error ? " bad" : "")}>
              <div className="ic" onClick={() => onOpen(p)}>
                {p.icon ? <img src={p.icon} alt="" /> : <span>{initials(p.name)}</span>}
              </div>
              <div className="bd" onClick={() => onOpen(p)}>
                <div className="nm">
                  {p.name}
                  <span className="v">v{p.version}</span>
                  {p.dev && <span className="pg-badge accent">开发中</span>}
                  {updatable.has(p.id) && <span className="pg-badge accent">有新版</span>}
                </div>
                <div className="ds">
                  {p.error ? (
                    <span className="bad">加载失败:{p.error}</span>
                  ) : (
                    contributesLine(p) || p.description || p.id
                  )}
                </div>
              </div>
              <div className="ac">
                {p.dev && (
                  <button type="button" className="btn sm" onClick={() => onReload(p)}>
                    重载
                  </button>
                )}
                <button type="button" className="ibtn" title="详情" onClick={() => onOpen(p)}>
                  <IconChevronRight size={16} />
                </button>
                <Sw
                  on={p.enabled}
                  disabled={busy === p.id || !!p.error}
                  onChange={() => (p.enabled ? onDisable(p) : onEnable(p))}
                />
              </div>
            </div>
          ))}
        </div>
      )}

      {/* 开发者入口。Obsidian 的做法:不给普通用户任何存在感,放最下面一行小字。 */}
      <div className="pg-dev">
        <span>做自己的插件?</span>
        <button type="button" className="pg-devbtn" onClick={onPickInstall}>安装本地 .ipk</button>
        <button type="button" className="pg-devbtn" onClick={onPickDev}>挂载开发目录(热重载)</button>
        <button
          type="button"
          className="pg-devbtn"
          onClick={() => openUrl("https://github.com/zzzwannasleep/LinplayerPluginsRepository")}
        >
          开发文档
        </button>
      </div>
    </>
  );
}

function contributesLine(p: PluginInfo): string {
  const c = p.contributes;
  if (!c) return "";
  const bits: string[] = [];
  if (c.dataSources) bits.push(`${c.dataSources} 个数据源`);
  if (c.panels) bits.push(`${c.panels} 个面板`);
  if (c.actions) bits.push(`${c.actions} 个操作`);
  if (c.sandboxViews) bits.push(`${c.sandboxViews} 个自定义界面`);
  return bits.length ? "提供 " + bits.join(" · ") : "";
}

/* ---------------- 插件源 ---------------- */

function SourcesTab({
  sources, onChange, onError, onOk,
}: {
  sources: PluginSource[];
  onChange: (s: PluginSource[]) => void;
  onError: (e: unknown) => void;
  onOk: (t: string) => void;
}) {
  const [name, setName] = useState("");
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState(false);

  async function add() {
    if (busy || !url.trim()) return;
    setBusy(true);
    try {
      onChange(await pluginMarketAddSource(name, url));
      setName("");
      setUrl("");
      onOk("已添加插件源");
    } catch (e) {
      onError(e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="pg-narrow">
      <h4>插件源</h4>
      <p className="hint">
        市场里的插件来自这些源。官方源可以停用但不能删除 —— 删掉之后要找回来只能手打地址。
      </p>

      <div className="pg-rows">
        {sources.map((s) => (
          <div key={s.id} className="pg-row src">
            <div className="bd">
              <div className="nm">
                {s.name}
                {s.builtin ? (
                  <span className="pg-badge good">官方</span>
                ) : (
                  <span className="pg-badge warn">第三方</span>
                )}
              </div>
              <div className="ds mono">{s.url}</div>
            </div>
            <div className="ac">
              {!s.builtin && (
                <button
                  type="button"
                  className="ibtn"
                  title="删除"
                  onClick={() =>
                    pluginMarketRemoveSource(s.id).then(onChange).catch(onError)
                  }
                >
                  <IconTrash size={16} />
                </button>
              )}
              <Sw
                on={s.enabled}
                onChange={(v) =>
                  pluginMarketToggleSource(s.id, v).then(onChange).catch(onError)
                }
              />
            </div>
          </div>
        ))}
      </div>

      <h4 style={{ marginTop: 20 }}>添加第三方源</h4>
      <p className="hint">
        填 registry.json 的完整地址。必须是 https(明文 http 只对本机开放)——
        这份索引决定了「装哪个包」,在半路被改一行就等于让你装上任意插件。
      </p>
      <div className="pg-addsrc">
        <input
          className="field"
          placeholder="源名称(可留空)"
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <input
          className="field"
          placeholder="https://example.com/registry.json"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && add()}
        />
        <button type="button" className="btn primary" disabled={busy || !url.trim()} onClick={add}>
          <IconPlus size={15} /> 添加
        </button>
      </div>
    </div>
  );
}

/* ---------------- 详情抽屉 ---------------- */

function DetailDrawer({
  market, local, hostApi, permById, busy, onClose, onInstall, onEnable, onDisable, onUninstall,
}: {
  market?: MarketPlugin;
  local?: PluginInfo;
  hostApi: number;
  permById: Map<string, PluginPermissionInfo>;
  busy: string | null;
  onClose: () => void;
  onInstall: (m: MarketPlugin) => void;
  onEnable: (p: PluginInfo) => void;
  onDisable: (p: PluginInfo) => void;
  onUninstall: (p: PluginInfo) => void;
}) {
  const [pane, setPane] = useState<Pane>("about");
  /* 插件自己的设置面板(slot: settings)放在**这里**而不是设置页的某个二级标签 ——
     用户找「这个插件怎么配」的第一反应是点开这个插件,VS Code 也是这么做的。
     插件没贡献设置面板时这个标签整个不出现。 */
  const [hasSettings, setHasSettings] = useState(false);
  useEffect(() => {
    if (!local?.enabled) { setHasSettings(false); return; }
    pluginPanels("settings")
      .then((ps) => setHasSettings(ps.some((p) => p.pluginId === local.id)))
      .catch(() => setHasSettings(false));
  }, [local?.id, local?.enabled]);
  const name = market?.name ?? local?.name ?? "";
  const icon = market?.icon ?? local?.icon ?? null;
  const author = market?.author ?? local?.author ?? "";
  const permissions = market?.permissions ?? local?.permissions ?? [];
  const best = market ? bestVersion(market, hostApi) : null;
  const id = market?.id ?? local?.id ?? "";

  return (
    <div className="pg-scrim" onClick={onClose}>
      <div className="pg-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="hd">
          <div className="ic">{icon ? <img src={icon} alt="" /> : <span>{initials(name)}</span>}</div>
          <div className="ti">
            <b>{name}</b>
            <span>
              {author || "未知作者"}
              {local ? ` · 已装 v${local.version}` : best ? ` · v${best.version}` : ""}
            </span>
            <span className="mono">{id}</span>
          </div>
          <button type="button" className="ibtn" onClick={onClose}>
            <IconClose size={16} />
          </button>
        </div>

        {market && !market.from_builtin && (
          <div className="pg-warn inline">
            来自第三方源「{market.source_name}」。这个源不由 LinPlayer 审核,
            装之前请确认你信任它的作者。
          </div>
        )}
        {local?.error && <div className="pg-warn inline bad">加载失败:{local.error}</div>}

        <div className="pg-tabs sub">
          {(
            [
              ...(hasSettings ? ([["settings", "设置"]] as [Pane, string][]) : []),
              ["about", "简介"],
              ["perm", `权限 (${permissions.length})`],
              ["log", "更新日志"],
              ["ver", "版本"],
            ] as [Pane, string][]
          ).map(([k, label]) => (
            <button
              key={k}
              type="button"
              className={"pg-tab" + (pane === k ? " on" : "")}
              onClick={() => setPane(k)}
            >
              {label}
            </button>
          ))}
        </div>

        <div className="bd scroll">
          {pane === "settings" && local && (
            <PluginSlot slot="settings" onlyPlugin={local.id} />
          )}

          {pane === "about" && (
            <>
              <p className="pg-desc">
                {market?.description || local?.description || "作者没有写介绍。"}
              </p>
              {!!market?.tags.length && (
                <div className="pg-chips">
                  {market.tags.map((t) => (
                    <span key={t} className="pill">{t}</span>
                  ))}
                </div>
              )}
              {local && contributesLine(local) && <p className="hint">{contributesLine(local)}</p>}
              {local?.httpAllowedHosts.length ? (
                <>
                  <h5>可访问的网络地址</h5>
                  <ul className="pg-hosts">
                    {local.httpAllowedHosts.map((h) => (
                      <li key={h} className="mono">
                        {h === "$sourceServer" ? "你自己填写的服务器地址" : h}
                      </li>
                    ))}
                  </ul>
                </>
              ) : null}
              {local?.homepage && (
                <button type="button" className="pv-link" onClick={() => openUrl(local.homepage!)}>
                  项目主页
                </button>
              )}
            </>
          )}

          {pane === "perm" && (
            <PermissionList ids={permissions} permById={permById} />
          )}

          {pane === "log" && (
            <div className="pg-log">
              {(market?.versions ?? []).length === 0 ? (
                <p className="hint">这个插件不在任何市场源里(本地安装或开发中),没有更新日志。</p>
              ) : (
                [...(market?.versions ?? [])]
                  .sort((a, b) => -cmpVersion(a.version, b.version))
                  .map((v) => (
                    <div key={v.version} className="ent">
                      <b>v{v.version}</b>
                      {v.published_at && <span>{v.published_at.slice(0, 10)}</span>}
                      <p>{v.changelog || "作者没有写更新说明。"}</p>
                    </div>
                  ))
              )}
            </div>
          )}

          {pane === "ver" && (
            <div className="pg-log">
              {(market?.versions ?? []).length === 0 ? (
                <p className="hint">本地安装的插件没有版本列表。</p>
              ) : (
                [...(market?.versions ?? [])]
                  .sort((a, b) => -cmpVersion(a.version, b.version))
                  .map((v) => {
                    const loadable = v.api_version === 0 || v.api_version <= hostApi;
                    return (
                      <div key={v.version} className="ent">
                        <b>v{v.version}</b>
                        {!loadable && <span className="pg-badge warn">需更新应用</span>}
                        {!v.sha256 && <span className="pg-badge warn">无校验和</span>}
                        {v.sha256 && <span className="pg-badge good">已校验</span>}
                        {market && loadable && (
                          <button
                            type="button"
                            className="btn sm"
                            disabled={busy === market.id || v.version === local?.version}
                            onClick={() =>
                              pluginMarketInstall(market.id, v.version).catch(() => {})
                            }
                          >
                            {v.version === local?.version ? "当前" : "装这版"}
                          </button>
                        )}
                      </div>
                    );
                  })
              )}
            </div>
          )}
        </div>

        <div className="ft">
          {local ? (
            <>
              <button
                type="button"
                className="btn danger"
                disabled={busy === local.id}
                onClick={() => onUninstall(local)}
              >
                卸载
              </button>
              <div className="spring" />
              {market && best && cmpVersion(best.version, local.version) > 0 && (
                <button
                  type="button"
                  className="btn"
                  disabled={busy === market.id}
                  onClick={() => onInstall(market)}
                >
                  更新到 v{best.version}
                </button>
              )}
              <button
                type="button"
                className="btn primary"
                disabled={busy === local.id || !!local.error}
                onClick={() => (local.enabled ? onDisable(local) : onEnable(local))}
              >
                {local.enabled ? "停用" : "启用"}
              </button>
            </>
          ) : market ? (
            <>
              <div className="spring" />
              <button
                type="button"
                className="btn primary"
                disabled={busy === market.id || !best}
                onClick={() => onInstall(market)}
              >
                {best ? "安装" : "需要更新 LinPlayer"}
              </button>
            </>
          ) : null}
        </div>
      </div>
    </div>
  );
}

/* ---------------- 权限 ---------------- */

function PermissionList({
  ids,
  permById,
}: {
  ids: string[];
  permById: Map<string, PluginPermissionInfo>;
}) {
  if (ids.length === 0) return <p className="hint">这个插件不需要任何权限。</p>;
  return (
    <ul className="pg-perms">
      {ids.map((pid) => {
        const p = permById.get(pid);
        return (
          <li key={pid} className={p?.dangerous ? "danger" : ""}>
            <IconShield size={15} />
            <div>
              {/* 词表没命中就把 id 原样摆出来,不能假装成一句好听的空话 */}
              <b>{p?.title ?? pid}</b>
              <span>{p?.description ?? "这个版本的应用不认识这个权限。"}</span>
            </div>
          </li>
        );
      })}
    </ul>
  );
}

/** 启用前的授权确认。Chrome 扩展的做法:一行一条人话,不做花哨包装。 */
function PermissionModal({
  plugin, permById, onCancel, onAllow,
}: {
  plugin: PluginInfo;
  permById: Map<string, PluginPermissionInfo>;
  onCancel: () => void;
  onAllow: () => void;
}) {
  const dangerous = plugin.permissions.filter((p) => permById.get(p)?.dangerous);
  return (
    <div className="pg-scrim center" onClick={onCancel}>
      <div className="pg-modal" onClick={(e) => e.stopPropagation()}>
        <h4>启用「{plugin.name}」</h4>
        <p className="hint">
          它将获得以下能力
          {dangerous.length > 0 && <>,其中 <b>{dangerous.length} 项涉及网络或你的数据</b></>}:
        </p>
        <div className="scroll">
          <PermissionList ids={plugin.permissions} permById={permById} />
          {plugin.httpAllowedHosts.length > 0 && (
            <>
              <h5>只能访问这些地址</h5>
              <ul className="pg-hosts">
                {plugin.httpAllowedHosts.map((h) => (
                  <li key={h} className="mono">
                    {h === "$sourceServer" ? "你自己填写的服务器地址" : h}
                  </li>
                ))}
              </ul>
            </>
          )}
        </div>
        <div className="ft">
          <button type="button" className="btn" onClick={onCancel}>取消</button>
          <button type="button" className="btn primary" onClick={onAllow}>同意并启用</button>
        </div>
      </div>
    </div>
  );
}
