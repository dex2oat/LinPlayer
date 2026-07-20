import { useCallback, useEffect, useState } from "react";
import {
  listAccounts,
  onAccountsChanged,
  probeLine,
  setActiveLine,
  setLines,
  syncLines,
  type AccountInfo,
  type ServerLine,
} from "@shared/api";
import type { Route } from "../App";
import { Icon } from "../app/icons";
import { FocusColumn, FocusItem } from "../components/Focus";

/** 线路管理(草稿 17)。**「线路」这个概念只出现在这一页** ——
    媒体库标题下、播放页副标题、服务器卡片一律不提线路,也不提地址。
    详情页那个「版本」面板选的是 MediaSource,和线路是两回事,别混。

    这页只干三件事:看每条线路通不通、测速、选一条当前生效。

    ★ **这是全站唯一允许显示 URL 的页面**(加服务器页也允许)。既然进来就是为了分辨
      「哪条线路」,不给地址就没法分辨 —— 名字可以重、可以空,地址不会。
    ★ **测速是显式按钮,进页不自动跑**。四条线路串行探测十几秒,进页就卡住很糟。
    ★ 逐条 probeLine 而不是整表 probeLines:整表要等最慢那条(6s 超时)才一起返回,
      表面上看就是「按了没反应」。逐条并发发出去,谁回来先填谁。 */

/** 一条线路的探测态。undefined = 没探过(灰点),"probing" = 测速中(黄点),
 *  number = 延迟毫秒(绿点),null = **探过确实不通**(红点)。
 *  「没探过」和「不通」必须分开,同色的话用户会以为全挂了。 */
type Probe = "probing" | number | null | undefined;

export default function LinesPage({
  serverId,
}: {
  /** 从服务器页操作面板带过来的账号主键(= AccountInfo.server)。
   *  省略时回落到当前活跃服务器 —— 直接从导航进来也不至于空页。 */
  serverId?: string;
  go: (r: Route) => void;
}) {
  const [acc, setAcc] = useState<AccountInfo | null>(null);
  const [probes, setProbes] = useState<Record<number, Probe>>({});
  const [toast, setToast] = useState<string | null>(null);

  const load = useCallback(() => {
    listAccounts()
      .then((list) =>
        setAcc(
          list.find((a) => a.server === serverId) ??
            list.find((a) => a.active) ??
            list[0] ??
            null,
        ),
      )
      .catch(() => setAcc(null));
  }, [serverId]);

  /* 切线路 / 同步线路都会广播账号表变更,这里只管重取。 */
  useEffect(() => {
    load();
    return onAccountsChanged(load);
  }, [load]);

  const say = useCallback((m: string) => {
    setToast(m);
    setTimeout(() => setToast(null), 3000);
  }, []);

  const lines: ServerLine[] = acc?.lines ?? [];

  const probeAll = () => {
    if (!acc) return;
    for (let i = 0; i < lines.length; i++) {
      setProbes((p) => ({ ...p, [i]: "probing" }));
      const idx = i;
      probeLine(acc.server, idx)
        .then((r) => setProbes((p) => ({ ...p, [idx]: r.ms })))
        /* 失败也要落成 null(红点),不能留在「测速中」—— 黄点转圈转到天荒地老 */
        .catch(() => setProbes((p) => ({ ...p, [idx]: null })));
    }
  };

  return (
    <>
      <FocusColumn focusKey="LINES">
        <div style={{ display: "flex", alignItems: "baseline", gap: 20, marginBottom: 8 }}>
          <div className="ptitle" style={{ margin: 0 }}>
            线路管理
          </div>
          <div style={{ fontSize: 19, color: "var(--tv-ink-3)" }}>{acc?.name ?? ""}</div>
          <div style={{ marginLeft: "auto", display: "flex", gap: 16 }}>
            <FocusItem className="btn fx" autoFocus onEnter={probeAll}>
              <Icon n="timer" className="ic ic-btn" />
              全部测速
            </FocusItem>
            {/* ★ 同步 ≠ 测速。它从服主部署的 emby_ext_domains 拉备用域名并表(只增不删)。
                supported=false 是**常态**(绝大多数服务器没装这个),不是错误,别弹红字。 */}
            <FocusItem
              className="btn fx"
              onEnter={() => {
                if (!acc) return;
                syncLines(acc.server)
                  .then((r) =>
                    say(
                      r.supported
                        ? `已同步,新增 ${r.added} 条(共 ${r.total} 条)`
                        : "该服务器没有提供线路同步",
                    ),
                  )
                  .catch((e) => say(String(e)));
              }}
            >
              <Icon n="refresh" className="ic ic-btn" />
              同步线路
            </FocusItem>
          </div>
        </div>
        <div className="psub" style={{ marginBottom: 30 }}>
          选中的线路对该服务器的所有请求生效,包括图片和播放流
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          {lines.length === 0 ? (
            /* 一条线路都没有 = 这台服务器只有登录时那个地址。照样把地址显示出来
               (这页就是干这个的),但它不是可切换的选项,所以不占焦点位。 */
            <div
              style={{ ...ROW, background: "#161a20", opacity: 0.55 }}
              className="dim"
            >
              <Dot color="var(--tv-ink-3)" />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 22, fontWeight: 600 }}>
                  默认地址
                  <span style={{ fontSize: 16, color: "var(--accent)", marginLeft: 12 }}>
                    当前使用
                  </span>
                </div>
                <Url>{acc?.line_url ?? ""}</Url>
              </div>
            </div>
          ) : (
            lines.map((l, i) => (
              <LineRow
                key={l.id || l.url}
                line={l}
                active={i === acc?.active_line}
                probe={probes[i]}
                onEnter={() => {
                  if (!acc) return;
                  setActiveLine(acc.server, i)
                    .then(() => say(`已切换到「${l.name || l.url}」`))
                    .catch((e) => say(String(e)));
                }}
                onDelete={() => {
                  if (!acc) return;
                  setLines(
                    acc.server,
                    lines.filter((_, n) => n !== i),
                  )
                    .then(() => {
                      setProbes({});
                      say("已删除该线路");
                    })
                    .catch((e) => say(String(e)));
                }}
              />
            ))
          )}
        </div>
      </FocusColumn>

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/* ------------------------------------------------------------ */

const ROW: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 24,
  padding: "22px 26px",
  borderRadius: 16,
};

/** 整行可聚焦,确认 = 切到这条线路。
 *  删除做成行尾的独立焦点项 —— 草稿里它在菜单键面板中,但菜单键要 Activity 转发
 *  (壳还没建),放在那后面等于现在删不掉。行尾一格是这一版能保证按得到的位置。 */
function LineRow({
  line,
  active,
  probe,
  onEnter,
  onDelete,
}: {
  line: ServerLine;
  active: boolean;
  probe: Probe;
  onEnter: () => void;
  onDelete: () => void;
}) {
  return (
    <div style={{ display: "flex", gap: 16, alignItems: "stretch" }}>
      <FocusItem
        className={active ? "" : "dim"}
        style={{
          ...ROW,
          flex: 1,
          minWidth: 0,
          background: active ? "var(--accent-soft)" : "#161a20",
          boxShadow: active ? "inset 0 0 0 2px var(--accent)" : undefined,
        }}
        onEnter={onEnter}
      >
        <Dot color={dotColor(probe)} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 22, fontWeight: 600 }}>
            {line.name || "未命名线路"}
            {/* ★ 「当前使用」用**文字**标注,不只靠颜色 —— 三米外色差不可靠。 */}
            {active && (
              <span style={{ fontSize: 16, color: "var(--accent)", marginLeft: 12 }}>
                当前使用
              </span>
            )}
          </div>
          <Url>{line.url}</Url>
          {line.remark && (
            <div style={{ fontSize: 15, color: "var(--tv-ink-3)", marginTop: 6 }}>
              {line.remark}
            </div>
          )}
        </div>
        <div style={{ textAlign: "right", flex: "none" }}>
          <Latency probe={probe} />
        </div>
      </FocusItem>

      <FocusItem
        className="btn ico fx"
        style={{ height: "auto", alignSelf: "stretch" }}
        onEnter={onDelete}
      >
        <Icon n="trash" className="ic ic-btn" />
      </FocusItem>
    </div>
  );
}

function Latency({ probe }: { probe: Probe }) {
  if (probe === undefined) return <div style={{ fontSize: 18, color: "var(--tv-ink-3)" }}>未测速</div>;
  if (probe === "probing") return <div style={{ fontSize: 20, color: "var(--warn)" }}>测速中…</div>;
  if (probe === null) return <div style={{ fontSize: 20, color: "var(--danger)" }}>不可达</div>;
  return (
    <div
      style={{
        fontSize: 24,
        fontWeight: 640,
        color: probe < 200 ? "var(--good)" : undefined,
      }}
    >
      {probe} ms
    </div>
  );
}

function Dot({ color }: { color: string }) {
  return (
    <div
      style={{
        width: 14,
        height: 14,
        borderRadius: "50%",
        background: color,
        flex: "none",
      }}
    />
  );
}

/** 地址用等宽字 —— 一串域名里认「哪个字符不一样」,等宽比比例字体快得多。 */
function Url({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontSize: 16,
        color: "var(--tv-ink-3)",
        marginTop: 8,
        fontFamily: "var(--mono)",
        overflow: "hidden",
        textOverflow: "ellipsis",
        whiteSpace: "nowrap",
      }}
    >
      {children}
    </div>
  );
}

function dotColor(p: Probe): string {
  if (p === "probing") return "var(--warn)";
  if (p === null) return "var(--danger)";
  if (typeof p === "number") return "var(--good)";
  return "var(--tv-ink-3)";
}
