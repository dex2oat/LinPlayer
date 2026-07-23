import { pluginAssetUrl } from "@shared/api";
import { PluginSlot } from "../components/PluginHost";
import { IconChevronLeft } from "../app/icons";

/* ============================================================
   插件的整页界面。两种形态,同一个壳:

   ① 描述树面板(slot 为 `page` 或 `sidebar` 的 panels)—— 宿主用自己的组件画;
   ② 沙箱视图(sandboxViews)—— 插件自带的网页,塞进一个独立 origin 的 iframe。

   为什么逃生舱必须是 iframe 而不是把 HTML 注进主文档:主窗口的 JS 上下文里有
   `__TAURI_INTERNALS__.invoke`,插件页面一旦同源就等于拿到宿主全部命令,
   rquickjs 那套权限模型直接作废。iframe + `lpplugin://` 独立 origin 才有边界。
   ============================================================ */

export type PluginViewRef = {
  pluginId: string;
  /** 显示用的插件名(拿不到就退回 id)。 */
  pluginName?: string;
  kind: "panel" | "sandbox";
  /** panel: 贡献点 id;sandbox: 贡献点 id。 */
  id: string;
  title: string;
  /** sandbox 专用:插件目录内的 html 相对路径。 */
  entry?: string;
  /** panel 专用:它挂在哪个 slot。 */
  slot?: string;
};

export default function PluginViewPage({
  view,
  onBack,
}: {
  view: PluginViewRef;
  onBack: () => void;
}) {
  return (
    <div className="page pgview">
      <div className="pgview-bar">
        <button type="button" className="btn sm" onClick={onBack}>
          <IconChevronLeft size={16} />
          返回
        </button>
        <div className="ttl">
          <b>{view.title}</b>
          {/* 副标题固定用插件 id:用插件名的话,当面板标题恰好等于插件名时
              (「界面块速查」就是)页头会连着写两遍同一个词。 */}
          <span className="mono">{view.pluginId}</span>
        </div>
      </div>

      {view.kind === "sandbox" ? (
        <iframe
          className="pgview-frame"
          title={view.title}
          src={pluginAssetUrl(view.pluginId, view.entry || "index.html")}
          /* 逃生舱的能力上限就写在这一行。
             allow-scripts:插件页面要能跑自己的 JS,这是它存在的意义;
             **不给** allow-same-origin —— 给了就等于把 iframe 拉回宿主 origin,
             整个隔离白做;
             **不给** allow-top-navigation —— 否则插件能把整个 App 导航走,
             单窗口 SPA 没有后退键回得来。 */
          sandbox="allow-scripts allow-forms allow-popups"
          referrerPolicy="no-referrer"
        />
      ) : (
        <div className="pgview-body">
          <PluginSlot slot={view.slot || "page"} onlyPlugin={view.pluginId} onlyId={view.id} hideTitle />
        </div>
      )}
    </div>
  );
}
