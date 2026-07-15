import { useEffect, useRef, useState } from "react";
import { type Item, type LoginResult, type ServerGroup, aggregateSearch, listItems, views } from "../lib/api";
import Poster from "./Poster";
import { IconSearch } from "../app/icons";
import "./SearchOverlay.css";

type Props = {
  session: LoginResult;
  onClose: () => void;
  /** serverId:该结果所属服务器(聚合搜可能跨服),宿主据此先切服务器再开详情。 */
  onOpenItem: (it: Item, serverId?: string) => void;
  onPlay: (it: Item) => void;
};

/** 全局搜索浮层(草稿 PAGE 9):Ctrl K 唤起、Esc 收起,聚合开关按服务器分组。 */
export default function SearchOverlay({ session, onClose, onOpenItem, onPlay }: Props) {
  const [q, setQ] = useState("");
  const [aggregate, setAggregate] = useState(true);
  const [groups, setGroups] = useState<ServerGroup[] | null>(null);
  const [local, setLocal] = useState<Item[] | null>(null);
  const [busy, setBusy] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // 输入防抖搜索。
  useEffect(() => {
    const kw = q.trim();
    if (!kw) {
      setGroups(null);
      setLocal(null);
      return;
    }
    setBusy(true);
    const t = window.setTimeout(async () => {
      try {
        if (aggregate) {
          setGroups(await aggregateSearch(kw));
          setLocal(null);
        } else {
          // 单服务器:用媒体库根搜(简化,先取各库再本地过滤)。
          const vs = await views();
          const all: Item[] = [];
          for (const v of vs) all.push(...(await listItems(v.id).catch(() => [])));
          setLocal(all.filter((it) => it.name.toLowerCase().includes(kw.toLowerCase())).slice(0, 40));
          setGroups(null);
        }
      } catch {
        setGroups([]);
      } finally {
        setBusy(false);
      }
    }, 320);
    return () => window.clearTimeout(t);
  }, [q, aggregate]);

  const pick = (it: Item, serverId?: string) => {
    onOpenItem(it, serverId); // 关浮层交给宿主(它可能要先切服务器)
  };
  const play = (it: Item) => {
    onClose();
    onPlay(it);
  };

  return (
    <div className="ovl-scrim" onClick={onClose}>
      <div className="ovl" onClick={(e) => e.stopPropagation()}>
        <div className="ovl-top">
          <div className="ovl-input">
            <IconSearch size={17} />
            <input
              ref={inputRef}
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="搜索片名 / 聚合…"
            />
          </div>
          <button className={`pill${aggregate ? " on-pill" : ""}`} onClick={() => setAggregate((v) => !v)}>
            聚合搜索
            <span className={`sw${aggregate ? " on" : ""}`} style={{ marginLeft: 4 }}>
              <i />
            </span>
          </button>
          <span className="kbd">Esc</span>
        </div>

        <div className="ovl-body">
          {busy && <div className="spinner" style={{ margin: "20px auto" }} />}
          {!q.trim() && <div className="empty" style={{ padding: "28px 4px" }}>输入片名开始搜索。聚合模式跨全部服务器。</div>}

          {groups?.map((g) => (
            <section key={g.server_id}>
              <div className="ovl-grouplab">{g.server_name}</div>
              <div className="rail">
                {g.items.map((it, i) => (
                  <div className="r-poster" key={it.id}>
                    <Poster
                      item={it}
                      session={session}
                      onOpen={(x) => pick(x, g.server_id)}
                      onPlay={play}
                      index={i}
                    />
                  </div>
                ))}
              </div>
            </section>
          ))}
          {groups && groups.length === 0 && <div className="empty">没有找到结果</div>}

          {local && (
            <div className="dense-grid" style={{ padding: "4px 0 8px" }}>
              {local.map((it, i) => (
                <Poster key={it.id} item={it} session={session} onOpen={pick} onPlay={play} index={i} />
              ))}
            </div>
          )}
          {local && local.length === 0 && <div className="empty">没有找到结果</div>}
        </div>
      </div>
    </div>
  );
}
