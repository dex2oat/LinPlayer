// GET /gh/:metric — 自建 shields.io endpoint 徽章，绕开 shields 公共 GitHub token 池
// （它经常「Unable to select next GitHub token from pool」把 stars/release/downloads 打成灰色）。
//
// :metric ∈ stars | stable | prerelease | downloads
//
// 可选环境变量（Cloudflare Pages → Settings → Environment variables，建议 Encrypted）：
//   GITHUB_TOKEN  任意 read-only PAT（无 scope 即可）。不配也能跑，但匿名限 60 次/小时/IP，
//                 配上后 5000/小时，更稳。
// 可选 KV 绑定（复用星图那个 STAR_CACHE，不用新建）：
//   STAR_CACHE    绑了之后每个徽章成功值会存一份；GitHub 抽风那一刻就**发上次好值**，
//                 而不是像 shields 那样直接变灰 —— 这正是本次自建要解决的问题。
//                 没绑也能跑，只是失败时会回退成灰色 n/a。
//
// README 徽章（label / logo / style 放在 shields URL 上，颜色/数值由本接口给）：
//   stars:      https://img.shields.io/endpoint?url=https://291277.xyz/gh/stars&logo=github&label=Stars
//   stable:     https://img.shields.io/endpoint?url=https://291277.xyz/gh/stable&label=stable
//   prerelease: https://img.shields.io/endpoint?url=https://291277.xyz/gh/prerelease&label=pre-release
//   downloads:  https://img.shields.io/endpoint?url=https://291277.xyz/gh/downloads&logo=github&label=downloads

const REPO = 'zzzwannasleep/LinPlayer';

export async function onRequestGet({ params, env, waitUntil }) {
  const metric = params.metric;
  const cfg = {
    stars: 'blue',
    stable: 'blue',
    prerelease: 'orange',
    downloads: 'green',
  };
  if (!(metric in cfg)) return badge(metric, 'unknown metric', 'lightgrey');
  const kvKey = `badge:v1:${metric}`;

  const headers = {
    'User-Agent': 'LinPlayer-badge',
    Accept: 'application/vnd.github+json',
  };
  if (env.GITHUB_TOKEN) headers.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  const gh = (path) => fetch(`https://api.github.com/repos/${REPO}${path}`, { headers });

  try {
    let message;
    if (metric === 'stars') {
      const r = await gh('');
      if (!r.ok) throw 0;
      message = Number((await r.json()).stargazers_count).toLocaleString('en-US');
    } else if (metric === 'stable') {
      const r = await gh('/releases/latest');
      if (!r.ok) throw 0;
      message = (await r.json()).tag_name || 'none';
    } else if (metric === 'prerelease') {
      // shields 的 include_prereleases 语义：GitHub 列表顺序里第一个非 draft 的 release
      const r = await gh('/releases?per_page=30');
      if (!r.ok) throw 0;
      const rel = (await r.json()).find((x) => !x.draft);
      message = rel ? rel.tag_name : 'none';
    } else {
      // downloads: 累加所有 release 全部 asset 的下载数，翻页取全
      let total = 0;
      for (let page = 1; page <= 20; page++) {
        const r = await gh(`/releases?per_page=100&page=${page}`);
        if (!r.ok) throw 0;
        const list = await r.json();
        for (const rel of list) for (const a of rel.assets || []) total += a.download_count || 0;
        if (list.length < 100) break;
      }
      message = compact(total);
    }
    // 成功:把好值存进 KV(后台写,不拖响应),供下次 GitHub 抽风时兜底。
    if (env.STAR_CACHE) {
      const put = env.STAR_CACHE.put(kvKey, message, { expirationTtl: 7 * 24 * 3600 }).catch(() => {});
      if (waitUntil) waitUntil(put);
    }
    return badge(labelFor(metric), message, cfg[metric]);
  } catch (_) {
    // GitHub 挂了:能掏到上次好值就发旧值(保持原色,不变灰);掏不到才回 n/a。
    if (env.STAR_CACHE) {
      const last = await env.STAR_CACHE.get(kvKey).catch(() => null);
      if (last) return badge(labelFor(metric), last, cfg[metric]);
    }
    return badge(labelFor(metric), 'n/a', 'lightgrey');
  }
}

function labelFor(m) {
  return { stars: 'Stars', stable: 'stable', prerelease: 'pre-release', downloads: 'downloads' }[m] || m;
}

// 1234 → 1.2k，对齐 shields downloads 的缩写风格
function compact(n) {
  if (n < 1000) return String(n);
  if (n < 1_000_000) return (n / 1000).toFixed(n < 10_000 ? 1 : 0).replace(/\.0$/, '') + 'k';
  return (n / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M';
}

function badge(label, message, color) {
  return new Response(
    JSON.stringify({ schemaVersion: 1, label, message: String(message), color }),
    {
      headers: {
        'content-type': 'application/json',
        // 30 分钟边缘缓存(4 徽章 ≈ 8 次/小时,匿名限流下也安全);过期后先发旧值、
        // 后台再刷(SWR),GitHub 抽风那一刻不至于裂成灰色。
        'cache-control': 'public, max-age=1800, s-maxage=1800, stale-while-revalidate=86400',
      },
    },
  );
}
