// GET /sentry/users — 把 Sentry「近 30 天活跃用户数」渲染为 shields.io endpoint 徽章 JSON。
//
// 需要在 Cloudflare Pages 项目的 Settings → Environment variables 里配置（务必 Encrypted）：
//   SENTRY_TOKEN  一个只带 org:read 权限的 Sentry Auth Token（别用上传符号那个写权限 token）
// 该路由在 /api/ 之外，不受 _middleware 共享密钥保护，可被 README 徽章直接引用。
//
// 数据源：Sentry Sessions API 的 count_unique(user)（即 Release Health 活跃用户）。
// README 徽章：
//   ![Active Users](https://img.shields.io/endpoint?url=https://linplayeroaproxy.pages.dev/sentry/users)

const ORG = 'linplayer';
const PROJECT_ID = '4511717262032896'; // 取自 DSN 末段（数字项目 ID）
const PERIOD = '30d';

export async function onRequestGet({ env, request }) {
  const token = env.SENTRY_TOKEN;
  const debug = new URL(request.url).searchParams.get('debug') === '1';
  if (!token) return badge('未配置 SENTRY_TOKEN', 'lightgrey');

  const api =
    `https://sentry.io/api/0/organizations/${ORG}/sessions/` +
    `?field=count_unique(user)&statsPeriod=${PERIOD}` +
    `&project=${PROJECT_ID}&interval=1d`;

  try {
    const r = await fetch(api, { headers: { Authorization: `Bearer ${token}` } });
    if (!r.ok) {
      // debug=1：吐上游状态码 + 报错文案（不含 token），便于定位权限/参数问题。
      if (debug) {
        const body = (await r.text()).slice(0, 300);
        return new Response(JSON.stringify({ status: r.status, body }), {
          headers: { 'content-type': 'application/json' },
        });
      }
      return badge('n/a', 'lightgrey');
    }
    const data = await r.json();
    const users = data?.groups?.[0]?.totals?.['count_unique(user)'] ?? 0;
    return badge(Number(users).toLocaleString('en-US'), 'brightgreen');
  } catch (e) {
    if (debug) {
      return new Response(JSON.stringify({ error: String(e && e.message || e) }), {
        headers: { 'content-type': 'application/json' },
      });
    }
    return badge('n/a', 'lightgrey');
  }
}

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
        // shields 侧缓存约 5 分钟，减少打 Sentry 频率
        'cache-control': 'public, max-age=300',
      },
    },
  );
}
