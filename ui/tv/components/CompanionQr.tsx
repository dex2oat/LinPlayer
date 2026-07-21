import { useEffect, useState } from "react";
import QRCode from "qrcode";
import { companionUrl, type CompanionStatus } from "@shared/api";

/** 手机控制台的二维码。首次启动页和设置页共用这一份 ——
 *  两处各画一遍的话,改文案/改尺寸一定会漏掉一处。
 *
 *  ★ 整块**不可聚焦**:上面没有任何要按的东西,进得去只会让遥控器多走两步。
 *  ★ 地址下面**明写出来**:扫码器识别不了时,手机浏览器上还能手敲。
 *  ★ **不许自己编失败原因**。上一版拿到 null 就写「未开启,或电视没连上局域网」——
 *    用户明明插着网线,看到这句话只会认为程序在胡说,而真因(开关默认值是 false)
 *    在界面上一个字都没有。现在原因由核层给,这里只负责显示。 */
export default function CompanionQr({
  size = 420,
  title = "手机扫码遥控",
  hint = "手机和电视连同一个 Wi-Fi,扫码即用。手机上能打字搜片、加服务器、改设置。",
}: {
  size?: number;
  title?: string;
  hint?: string;
}) {
  const [qr, setQr] = useState<string | null>(null);
  const [st, setSt] = useState<CompanionStatus | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    companionUrl()
      .then(async (s) => {
        if (!alive) return;
        setSt(s);
        if (s.url) setQr(await QRCode.toDataURL(s.url, { margin: 1, width: size }));
      })
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [size]);

  /* 三种"扫不了"要分开说,因为用户的下一步动作完全不同:
     关着 → 去拨开关;探不到 IP → 查网络(但服务其实在跑,端口给出来能自查);
     没起来 → 是我们的 bug,把原因原样显示,让用户能截图给我。 */
  const problem = err ?? st?.error ?? null;

  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", textAlign: "center" }}>
      {title && (
        <div style={{ fontSize: 26, fontWeight: 640, marginBottom: 10 }}>{title}</div>
      )}
      <div
        style={{
          fontSize: 18,
          color: "var(--tv-ink-3)",
          marginBottom: 22,
          lineHeight: 1.6,
          maxWidth: size + 60,
        }}
      >
        {hint}
      </div>

      <div
        style={{
          width: size,
          height: size,
          borderRadius: 20,
          background: "#fff",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          overflow: "hidden",
        }}
      >
        {qr ? (
          <img src={qr} alt="" style={{ width: "100%", height: "100%" }} />
        ) : (
          <div style={{ color: "#666", fontSize: 18, padding: 24 }}>
            {problem ? "暂时扫不了" : "生成中…"}
          </div>
        )}
      </div>

      {st?.url && (
        <div style={{ fontSize: 18, color: "var(--tv-ink-2)", marginTop: 18 }}>{st.url}</div>
      )}
      {problem && (
        <div style={{ fontSize: 17, color: "var(--danger)", marginTop: 14, maxWidth: size + 60 }}>
          {problem}
          {/* 服务在跑、只是报不出 IP:把端口给出来,用户在手机上试 http://电视IP:端口 就能自查。 */}
          {st?.running && st.port != null && !st.url && (
            <div style={{ color: "var(--tv-ink-3)", marginTop: 8 }}>
              服务在监听 {st.port} 端口,可在手机浏览器直接访问 http://电视的IP:{st.port}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
