import { useEffect, useState } from "react";

/** 一段独立加载的数据。

    ★ 每块各自加载,**不要 Promise.all 屏障**。
      PC 端实测过:把首页几块并到一个 Promise.all 里等齐再渲染,首屏比各块各渲染慢 5.5 倍
      —— 慢的是加载结构,不是动画。见 [[perceived-slowness-is-animation]]。
      TV 上更严重:机顶盒网络更慢,等齐 = 整屏白到用户以为死机。

    ★ `initial` —— 缓存命中时**别再闪一次「载入中…」**。
      用户报的「图片、简介没做持久化,每次打开都要更新」,病根不在缓存(核层 imgcache
      2GB/30 天、api.ts 列表/详情 5 分钟 TTL 都在),而在这里:原来无条件
      `loading = true`,于是缓存明明命中,页面还是先整屏空一下再画出来 ——
      看起来和"每次都重新加载"一模一样。桌面早就用 peekItemDetail 先画再刷新了。

      传的是**函数**不是值:deps 变了(换条目/换集)要重新偷看新 id 的缓存,
      传值的话只有首次挂载那一下是对的,之后永远是旧条目的种子。
      不传 = 行为与改造前逐字相同(向后兼容,现有调用点一个都不用改)。 */
export function useAsync<T>(
  fn: () => Promise<T>,
  deps: unknown[] = [],
  initial?: () => T | undefined,
) {
  const [data, setData] = useState<T | null>(() => initial?.() ?? null);
  const [err, setErr] = useState<Error | null>(null);
  const [loading, setLoading] = useState(() => initial?.() === undefined);

  useEffect(() => {
    let alive = true;
    const seed = initial?.();
    /* 有种子就直接上屏、且**不进 loading 空态**;拿到新数据再原地替换。
       没种子时一个字都不改,和原来一样。 */
    if (seed !== undefined) setData(seed);
    setLoading(seed === undefined);
    setErr(null);
    fn()
      .then((v) => alive && (setData(v), setLoading(false)))
      .catch((e) => {
        if (!alive) return;
        setErr(e instanceof Error ? e : new Error(String(e)));
        setLoading(false);
      });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return { data, err, loading };
}
