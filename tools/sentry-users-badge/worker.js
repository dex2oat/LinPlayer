// Cloudflare Worker：把 Sentry「近 30 天活跃用户数」暴露成 shields.io endpoint 徽章。
//
// 为什么要它：shields.io 只能读公开 URL，而查 Sentry 要带 token。这个 Worker 拿着
// 存在加密环境变量里的 token 去问 Sentry，只对外返回一个数字，token 不出 Worker。
//
// 部署：
//   1) wrangler secret put SENTRY_TOKEN   # 粘贴带 org:read 权限的 Sentry Auth Token
//   2) wrangler deploy
//   3) README 徽章：
//      ![Active Users](https://img.shields.io/endpoint?url=https://<你的worker域名>/)
//
// 数据源：Sessions API 的 count_unique(user)（即 Release Health 的活跃用户）。

const ORG = 'linplayer';
const PROJECT_ID = '4511717262032896'; // 取自 DSN 末段（数字项目 ID）
const PERIOD = '30d';

function badge(message, color) {
  return new Response(
    JSON.stringify({
      schemaVersion: 1,
      label: 'active users',
      message: String(message),
      color,
    }),
    {
      headers: {
        'content-type': 'application/json',
        // shields 侧缓存约 5 分钟，避免频繁打 Sentry
        'cache-control': 'public, max-age=300',
        'access-control-allow-origin': '*',
      },
    },
  );
}

export default {
  async fetch(request, env) {
    if (request.method !== 'GET') return badge('n/a', 'lightgrey');

    const api =
      `https://sentry.io/api/0/organizations/${ORG}/sessions/` +
      `?field=count_unique(user)&statsPeriod=${PERIOD}` +
      `&project=${PROJECT_ID}&interval=1d`;

    try {
      const r = await fetch(api, {
        headers: { Authorization: `Bearer ${env.SENTRY_TOKEN}` },
      });
      if (!r.ok) return badge('n/a', 'lightgrey');

      const data = await r.json();
      const users = data?.groups?.[0]?.totals?.['count_unique(user)'] ?? 0;
      return badge(users.toLocaleString('en-US'), 'brightgreen');
    } catch (_) {
      return badge('n/a', 'lightgrey');
    }
  },
};
