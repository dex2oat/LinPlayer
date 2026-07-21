import { useEffect, useState } from "react";
import QRCode from "qrcode";
import { companionUrl } from "@shared/api";

/** 手机控制台的二维码。首次启动页和设置页共用这一份 ——
 *  两处各画一遍的话,改文案/改尺寸一定会漏掉一处。
 *
 *  ★ 整块**不可聚焦**:上面没有任何要按的东西,进得去只会让遥控器多走两步。
 *  ★ 地址下面**明写出来**:扫码器识别不了时,手机浏览器上还能手敲。 */
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
  const [url, setUrl] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    companionUrl()
      .then(async (u) => {
        if (!alive) return;
        if (!u) {
          /* null 有两种可能,但对用户是同一件事:现在扫不了。
             不编造"服务已关闭"这类具体原因 —— 真机上更常见的是没连上局域网。 */
          setErr("手机遥控未开启,或电视没连上局域网");
          return;
        }
        setUrl(u);
        setQr(await QRCode.toDataURL(u, { margin: 1, width: size }));
      })
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [size]);

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
            {err ? "暂时扫不了" : "生成中…"}
          </div>
        )}
      </div>

      {url && (
        <div style={{ fontSize: 18, color: "var(--tv-ink-2)", marginTop: 18 }}>{url}</div>
      )}
      {err && (
        <div style={{ fontSize: 17, color: "var(--danger)", marginTop: 14, maxWidth: size }}>
          {err}
        </div>
      )}
    </div>
  );
}
