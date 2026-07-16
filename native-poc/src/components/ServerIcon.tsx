import { useEffect, useState } from "react";
import { accountIcon } from "../lib/api";

/** icon_url 一字段兼四态:内置字形(短串)/ 网络图(http)/ data URI / 本地路径。
    判据同 ServersPage:短且无路径分隔符 = 字形。 */
export const isGlyph = (s: string) => s.length <= 2 && !/[\\/:.]/.test(s);

/**
 * 服务器图标(侧栏 + 服务器页共用形态)。自解析:
 *   - http/data URI → 直接 <img>(webview 能直接拉);
 *   - 本地路径 → 找核层要缓存后的 data URI(accountIcon 负责下载/缓存);
 *   - 字形 → 文本;
 *   - 都没有 → /emby_default.png 兜底(**不是**内置第一个字形,用户 2026-07-16 点名)。
 *
 * ★ 为什么侧栏要它:此前侧栏切换器写死「▣」、下拉项根本不画图标 —— 于是「在服务器页
 *   改了图标,侧栏纹丝不动」。真因不是广播不通(广播早就有),是侧栏压根没渲染图标。
 */
export default function ServerIcon({
  server,
  icon,
  size = 20,
}: {
  server: string;
  icon?: string | null;
  size?: number;
}) {
  const [uri, setUri] = useState<string | null>(null);
  const glyph = icon && isGlyph(icon) ? icon : null;
  const direct = icon && (icon.startsWith("http") || icon.startsWith("data:")) ? icon : null;
  const needsResolve = !!icon && !glyph && !direct; // 本地路径,得找核层要 data URI

  useEffect(() => {
    if (!needsResolve) {
      setUri(null);
      return;
    }
    let alive = true;
    accountIcon(server)
      .then((d) => alive && setUri(d))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [server, icon, needsResolve]);

  const src = direct ?? uri;
  if (src) return <img className="sv-sic-img" src={src} alt="" />;
  if (glyph) return <span className="sv-glyph" style={{ fontSize: size }}>{glyph}</span>;
  return <img className="sv-sic-img" src="/emby_default.png" alt="" width={size} height={size} />;
}
