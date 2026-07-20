import { useEffect, useState } from "react";

/** 一段独立加载的数据。

    ★ 每块各自加载,**不要 Promise.all 屏障**。
      PC 端实测过:把首页几块并到一个 Promise.all 里等齐再渲染,首屏比各块各渲染慢 5.5 倍
      —— 慢的是加载结构,不是动画。见 [[perceived-slowness-is-animation]]。
      TV 上更严重:机顶盒网络更慢,等齐 = 整屏白到用户以为死机。 */
export function useAsync<T>(fn: () => Promise<T>, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [err, setErr] = useState<Error | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    setLoading(true);
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
