import { useEffect, useState } from "react";
import { isAdmin, refreshItem, scanLibraries } from "./api";
import { IconLibrary, IconRefresh, IconSearch } from "../app/icons";

/** 当前账号是不是管理员。非管理员/探测失败一律 false —— 宁可少给按钮,也别给一点就 403 的按钮。
 *
 * 每次 server 变了重探:同一个客户端换服务器,权限当然会变。
 * 不缓存到本地:管理员位是服务端的话,存下来就有「被降权了还留着按钮」这种状态。 */
export function useIsAdmin(server: string): boolean {
  const [admin, setAdmin] = useState(false);
  useEffect(() => {
    let alive = true;
    setAdmin(false);
    isAdmin()
      .then((a) => alive && setAdmin(a))
      .catch(() => alive && setAdmin(false));
    return () => {
      alive = false;
    };
  }, [server]);
  return admin;
}

type Props = {
  /** 作用对象:库卡片给库 id,影片卡给条目 id。 */
  itemId: string;
  /** 动作发出后的反馈(成功/失败都走这);同时用来关菜单。 */
  onDone: (msg: string) => void;
  /** 上面还有别的菜单项时画分隔线;整个菜单只有这三项时(库卡片)不画。 */
  divider?: boolean;
};

/* 对标 Emby web。三项打的**真实端点**(名字容易混,这里钉死):
     刷新媒体库 → POST /Items/{id}/Refresh  Default(只补缺失,不动已有元数据)
     扫描媒体库 → POST /Library/Refresh     整台服务器找新文件
     刷新元数据 → POST /Items/{id}/Refresh  FullRefresh(强制重刮,替换已有元数据)

   全是**异步任务**:服务端收下就返回,活在后台跑。所以提示只说「已下发」,
   不说「已完成」—— 说完成是骗人,库大的时候要跑好几分钟。 */
export function AdminMenuItems({ itemId, onDone, divider = true }: Props) {
  const run = (label: string, fn: () => Promise<void>) => () => {
    fn()
      .then(() => onDone(`${label}:已下发,服务端后台执行`))
      .catch((e) => onDone(`${label}失败:${e}`));
  };

  return (
    <>
      {divider && <div className="mi-div" />}
      <div className="mi" onClick={run("刷新媒体库", () => refreshItem(itemId, false))}>
        <IconRefresh size={15} /> 刷新媒体库
      </div>
      <div className="mi" onClick={run("扫描媒体库", () => scanLibraries())}>
        <IconSearch size={15} /> 扫描媒体库
      </div>
      <div className="mi" onClick={run("刷新元数据", () => refreshItem(itemId, true))}>
        <IconLibrary size={15} /> 刷新元数据
      </div>
    </>
  );
}
