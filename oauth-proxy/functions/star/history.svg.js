// GET /star/history.svg — 实时渲染本仓库的 star 增长曲线为一张自包含 SVG。
//
// 为什么自己做:star-history.com 只有热缓存的仓库能秒出,没命中就现场去 GitHub 拉数据,
// 超过它自己 10 秒上限就直接 500。实测(2026-07-19)连 facebook/react 都是 500,
// 响应体 `timeout of 10000ms exceeded` —— 所以 README 里那张图才会「时不时看不了」。
// 这个路由把数据源换成我们自己的边缘节点,并且用 stale-while-revalidate 兜底:
// 就算 GitHub 那一刻挂了,也是**发旧图**,而不是发白板。
//
// 用法(README 里配 <picture> 双主题):
//   /star/history.svg          浅色
//   /star/history.svg?theme=dark  深色
//   /star/history.svg?repo=owner/name   换仓库(默认 DEFAULT_REPO)
//
// 环境变量(Cloudflare Pages):
//   GITHUB_TOKEN  **必填**(设为 Encrypted)。
//                 实测(2026-07-19):`GET /repos/{o}/{r}/stargazers` 匿名访问直接 401
//                 `Requires authentication` —— 限流还剩 36 次也一样,不是额度问题,
//                 GitHub 就是不让匿名读 stargazers 列表了。而 star 时间(starred_at)
//                 只有这个端点给,所以没 token 就画不出曲线,没有绕路可走。
//                 只读公开数据,建一个**不勾任何权限**的 fine-grained token 就够。
//
// KV 绑定(可选,但仓库越大越该绑):
//   STAR_CACHE    Workers KV namespace。绑了之后:
//                   · star 时间线**增量**同步 —— 每次刷新只拉新增的那一两页,
//                     不管仓库多大都是 1~2 个子请求(不绑的话每次冷刷都要 30 个);
//                   · 曲线保持**全量精度**,不再因为仓库变大而降级成采样;
//                   · GitHub 挂了也照样出图(库里就有全套数据),不只靠 SWR 那点窗口。
//                 没绑就自动退回「采样 + 每次现拉」,功能不缺,只是精度和成本差一截。
//
// 该路由在 /api/ 之外,不受共享密钥保护,可直接被 README 图片引用(同 /afdian/sponsors.svg)。

const DEFAULT_REPO = 'zzzwannasleep/LinPlayer';
// CF 免费版每请求子请求上限 ~50。留足余量:最多打 30 次 GitHub。
const MAX_REQUESTS = 30;
const PER_PAGE = 100;
/** KV 里的时间线多久算新鲜。过期不代表不能用 —— 过期的照样先拿去画,只是顺手后台刷。 */
const FRESH_MS = 5 * 60 * 1000;
/** 折线最多画多少个点。再多 SVG 会白白变大,而 680px 宽也画不出那么多细节。 */
const MAX_PLOT_POINTS = 400;

export async function onRequestGet({ request, env, waitUntil }) {
  const url = new URL(request.url);
  const repo = (url.searchParams.get('repo') || DEFAULT_REPO).trim();
  const dark = url.searchParams.get('theme') === 'dark';
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) {
    return svgResponse(messageSvg('仓库名不合法', dark), 400);
  }
  // 早退且把话说明白:没 token 时 GitHub 会回一个含糊的 401,让人以为是 token 填错了。
  if (!env.GITHUB_TOKEN) {
    return svgResponse(messageSvg('未配置 GITHUB_TOKEN(stargazers 接口不允许匿名读)', dark));
  }

  try {
    const { points, total } = env.STAR_CACHE
      ? await cachedStarHistory(repo, env, waitUntil)
      : await fetchStarHistory(repo, env.GITHUB_TOKEN);
    if (points.length < 2) {
      return svgResponse(messageSvg(`${repo} 的 star 还太少,画不出曲线`, dark));
    }
    return svgResponse(renderChart(repo, points, total, dark));
  } catch (e) {
    // 失败也要回 200 + 一张写着原因的图:回 4xx/5xx 的话 GitHub 只会显示裂图,
    // 谁都不知道为什么。图上写字,你一眼就能看出是限流还是仓库名写错了。
    return svgResponse(messageSvg(String((e && e.message) || e), dark));
  }
}

/* ---- KV 缓存(增量同步) ----

   存的是一条**只增不减**的时间线:ts[i] = 第 i+1 颗 star 的时间(秒)。
   count 不用存 —— 它就是下标 +1。25 万颗 star 存下来也就 ~1.5MB,离 KV 的 25MB 很远。

   增量的原理:GitHub 的 stargazers 列表是**按加星时间升序**分页的,新来的 star 永远在
   最后一页。所以已经存了 N 颗,就只用从第 floor(N/100)+1 页拉到最后一页 —— 通常 1~2 页,
   **和仓库有多大无关**。这正是"仓库长大了也没事"的那个点。 */

const KV_VERSION = 1;

async function cachedStarHistory(repo, env, waitUntil) {
  const key = `stars:v${KV_VERSION}:${repo}`;
  const cached = await env.STAR_CACHE.get(key, 'json').catch(() => null);
  const fresh = cached && Date.now() - cached.at < FRESH_MS;

  if (fresh) return fromTimeline(cached);

  // 有旧数据就先拿去画,同步放后台 —— 用户永远不为一次回源等待。
  if (cached && cached.ts && cached.ts.length >= 2) {
    const job = syncTimeline(repo, env, key, cached).catch(() => {});
    if (waitUntil) waitUntil(job);
    return fromTimeline(cached);
  }

  // 冷启动:必须同步等一次,否则第一张图是空的。
  const filled = await syncTimeline(repo, env, key, null);
  return fromTimeline(filled);
}

/** 拉新增部分并写回 KV,返回完整时间线对象。 */
async function syncTimeline(repo, env, key, cached) {
  const token = env.GITHUB_TOKEN;
  const meta = await ghJson(`https://api.github.com/repos/${repo}`, token);
  const total = meta.stargazers_count || 0;

  let ts = (cached && cached.ts) || [];
  /* 取关(unstar)会让整个分页往前挪,已存的页边界就对不上了。差得不多无所谓
     (曲线上看不出来),差太多就整条重建 —— 宁可多花一次全量,也别留一条越漂越歪的线。 */
  if (total < ts.length - 50) ts = [];

  const totalPages = Math.ceil(total / PER_PAGE);
  // 已有 N 颗 → 从它所在那一页接着拉(那页可能只装了一半,要重拉并覆盖)。
  const startPage = Math.max(1, Math.floor(ts.length / PER_PAGE) + 1);
  const endPage = Math.min(totalPages, startPage + (MAX_REQUESTS - 2));

  for (let p = startPage; p <= endPage; p++) {
    const page = await ghJson(
      `https://api.github.com/repos/${repo}/stargazers?per_page=${PER_PAGE}&page=${p}`,
      token,
    );
    if (!page.length) break;
    const base = (p - 1) * PER_PAGE;
    page.forEach((s, i) => {
      const t = Date.parse(s.starred_at);
      if (!Number.isNaN(t)) ts[base + i] = Math.floor(t / 1000);
    });
    if (page.length < PER_PAGE) break; // 最后一页
  }

  ts = ts.filter((v) => typeof v === 'number'); // 万一中间有洞(理论上不会),别留 undefined
  const out = { v: KV_VERSION, at: Date.now(), total, ts };
  await env.STAR_CACHE.put(key, JSON.stringify(out)).catch(() => {});
  return out;
}

function fromTimeline(c) {
  return {
    points: downsample(c.ts.map((t, i) => ({ t: t * 1000, n: i + 1 })), MAX_PLOT_POINTS),
    total: c.total,
  };
}

/** 等距抽稀,但**首尾必留** —— 丢了末点,曲线就画不到"现在"。 */
function downsample(points, max) {
  if (points.length <= max) return points;
  const step = (points.length - 1) / (max - 1);
  const out = [];
  for (let i = 0; i < max; i++) out.push(points[Math.round(i * step)]);
  return out;
}

// ---- GitHub API ----

function gh(token) {
  const h = {
    // star+json 才会在每条记录里带 starred_at;默认的 json 只有用户信息,没有时间。
    Accept: 'application/vnd.github.star+json',
    'User-Agent': 'LinPlayer-star-history',
  };
  if (token) h.Authorization = `Bearer ${token}`;
  return h;
}

async function ghJson(url, token) {
  const r = await fetch(url, { headers: gh(token) });
  if (r.status === 403 || r.status === 429) {
    const left = r.headers.get('x-ratelimit-remaining');
    throw new Error(
      left === '0'
        ? 'GitHub 限流(未配置 GITHUB_TOKEN 时只有 60 次/小时)'
        : 'GitHub 拒绝了请求(403)',
    );
  }
  if (r.status === 404) throw new Error('仓库不存在或不可见');
  if (!r.ok) throw new Error(`GitHub HTTP ${r.status}`);
  return r.json();
}

/** 返回 [{t: Date毫秒, n: 累计star数}],以及当前总数。 */
async function fetchStarHistory(repo, token) {
  const meta = await ghJson(`https://api.github.com/repos/${repo}`, token);
  const total = meta.stargazers_count || 0;
  if (total === 0) return { points: [], total };

  const totalPages = Math.ceil(total / PER_PAGE);
  const budget = MAX_REQUESTS - 1; // 上面那次 meta 也算一个子请求

  const list = (p) =>
    ghJson(`https://api.github.com/repos/${repo}/stargazers?per_page=${PER_PAGE}&page=${p}`, token);

  const points = [];
  if (totalPages <= budget) {
    // 全量:每个 star 一个点,曲线是精确的。
    const pages = await Promise.all(rangeInclusive(1, totalPages).map(list));
    let n = 0;
    for (const page of pages) {
      for (const s of page) {
        n += 1;
        const t = Date.parse(s.starred_at);
        if (!Number.isNaN(t)) points.push({ t, n });
      }
    }
  } else {
    /* 采样:仓库大到一次拉不完时,按页均匀取样,每页只用**第一条**的时间,
       它的累计序号必然是 (page-1)*PER_PAGE + 1。这正是 star-history 的做法,
       曲线形状不受影响(star 曲线本来就是单调的)。 */
    const picks = evenlySpaced(1, totalPages, budget);
    const pages = await Promise.all(picks.map(list));
    picks.forEach((p, i) => {
      const first = pages[i] && pages[i][0];
      if (!first) return;
      const t = Date.parse(first.starred_at);
      if (!Number.isNaN(t)) points.push({ t, n: (p - 1) * PER_PAGE + 1 });
    });
  }

  // 收尾点:把曲线拉到「此刻的总数」。没有它,图永远差最后一段。
  const last = points[points.length - 1];
  if (last && last.n < total) points.push({ t: Date.now(), n: total });
  points.sort((a, b) => a.t - b.t);
  return { points: downsample(points, MAX_PLOT_POINTS), total };
}

function rangeInclusive(a, b) {
  const out = [];
  for (let i = a; i <= b; i++) out.push(i);
  return out;
}

/** 在 [a,b] 里等距取 count 个整数页码(含首尾,去重升序)。 */
function evenlySpaced(a, b, count) {
  const out = new Set([a, b]);
  for (let i = 1; i < count - 1; i++) {
    out.add(Math.round(a + ((b - a) * i) / (count - 1)));
  }
  return [...out].sort((x, y) => x - y);
}

// ---- SVG 渲染 ----

const THEME = {
  light: { bg: '#ffffff', border: '#d0d7de', grid: '#eaeef2', ink: '#24292f', dim: '#57606a', line: '#e3b341', fill: 'rgba(227,179,65,0.16)' },
  dark: { bg: '#0d1117', border: '#30363d', grid: '#21262d', ink: '#e6edf3', dim: '#8b949e', line: '#e3b341', fill: 'rgba(227,179,65,0.14)' },
};

function renderChart(repo, points, total, dark) {
  const c = dark ? THEME.dark : THEME.light;
  const W = 680, H = 380;
  const L = 62, R = 22, T = 54, B = 44; // 四边留白
  const pw = W - L - R, ph = H - T - B;

  const t0 = points[0].t, t1 = points[points.length - 1].t;
  const nMax = Math.max(total, points[points.length - 1].n);
  const yTop = niceCeil(nMax);
  const x = (t) => L + (t1 === t0 ? pw : ((t - t0) / (t1 - t0)) * pw);
  const y = (n) => T + ph - (n / yTop) * ph;

  // 网格 + 刻度
  let grid = '';
  const yTicks = 4;
  for (let i = 0; i <= yTicks; i++) {
    const v = (yTop / yTicks) * i;
    const yy = y(v).toFixed(1);
    grid += `<line x1="${L}" y1="${yy}" x2="${W - R}" y2="${yy}" stroke="${c.grid}" stroke-width="1"/>` +
      `<text x="${L - 10}" y="${yy}" font-size="11" fill="${c.dim}" text-anchor="end" dominant-baseline="central">${fmtNum(v)}</text>`;
  }
  const xTicks = 4;
  for (let i = 0; i <= xTicks; i++) {
    const t = t0 + ((t1 - t0) / xTicks) * i;
    const xx = x(t).toFixed(1);
    grid += `<text x="${xx}" y="${H - B + 20}" font-size="11" fill="${c.dim}" text-anchor="middle">${fmtDate(t)}</text>`;
  }

  // 折线 + 面积。star 曲线是阶梯式增长,用直线段连即可(点已足够密)。
  const d = points.map((p, i) => `${i ? 'L' : 'M'}${x(p.t).toFixed(1)},${y(p.n).toFixed(1)}`).join('');
  const area = `${d}L${x(t1).toFixed(1)},${(T + ph).toFixed(1)}L${x(t0).toFixed(1)},${(T + ph).toFixed(1)}Z`;

  const lastX = x(t1).toFixed(1), lastY = y(nMax).toFixed(1);

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif">` +
    `<rect x="0.5" y="0.5" width="${W - 1}" height="${H - 1}" rx="10" fill="${c.bg}" stroke="${c.border}"/>` +
    `<text x="${L - 40}" y="30" font-size="15" font-weight="700" fill="${c.ink}">★ ${escapeXml(repo)}</text>` +
    `<text x="${W - R}" y="30" font-size="15" font-weight="700" fill="${c.line}" text-anchor="end">${fmtNum(total)}</text>` +
    grid +
    `<path d="${area}" fill="${c.fill}"/>` +
    `<path d="${d}" fill="none" stroke="${c.line}" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"/>` +
    `<circle cx="${lastX}" cy="${lastY}" r="3.5" fill="${c.line}"/>` +
    `</svg>`;
}

function messageSvg(text, dark) {
  const c = dark ? THEME.dark : THEME.light;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="560" height="72" viewBox="0 0 560 72" font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif">` +
    `<rect x="0.5" y="0.5" width="559" height="71" rx="10" fill="${c.bg}" stroke="${c.border}"/>` +
    `<text x="20" y="42" font-size="13" fill="${c.dim}">★ Star History：${escapeXml(text)}</text></svg>`;
}

function svgResponse(svg, status = 200) {
  return new Response(svg, {
    status,
    headers: {
      'Content-Type': 'image/svg+xml; charset=utf-8',
      /* 5 分钟内边缘直出(所以「实时」不等于每次都打 GitHub);过期后**先发旧图、
         后台再刷新**(stale-while-revalidate)。这是不白板的关键:GitHub 抽风那一刻,
         用户看到的是稍旧的曲线,而不是裂图 —— star-history 就是差这一步。 */
      'Cache-Control': 'public, max-age=300, s-maxage=300, stale-while-revalidate=86400',
    },
  });
}

// ---- 工具 ----

function niceCeil(n) {
  if (n <= 10) return 10;
  const mag = Math.pow(10, Math.floor(Math.log10(n)));
  for (const m of [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) {
    if (n <= m * mag) return m * mag;
  }
  return 10 * mag;
}
function fmtNum(n) {
  const v = Math.round(n);
  return v >= 1000 ? (v / 1000).toFixed(v % 1000 === 0 ? 0 : 1) + 'k' : String(v);
}
function fmtDate(t) {
  const d = new Date(t);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}
function escapeXml(s) {
  return String(s).replace(/[&<>"']/g, (ch) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}
