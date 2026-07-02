// 全局中间件：为 /api/* 提供 CORS 与可选的共享密钥校验。
//
// 说明：
// - LinPlayer 客户端用 dio 发请求（非浏览器），CORS 其实不生效，这里加上只是
//   方便你用浏览器/curl 调试。
// - LINPLAYER_PROXY_KEY 是「可选」的共享密钥：设置后，只有携带相同
//   X-LinPlayer-Key 头的请求才被放行，可挡掉大部分顺手刷你代理的脚本。
//   它本身也随客户端分发、可被提取，只是再加一道门槛，并非强鉴权。

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-LinPlayer-Key',
    'Access-Control-Max-Age': '86400',
  };
}

export async function onRequest(context) {
  const { request, env, next } = context;
  const url = new URL(request.url);

  if (request.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders() });
  }

  if (url.pathname.startsWith('/api/')) {
    const required = env.LINPLAYER_PROXY_KEY;
    if (required) {
      const got = request.headers.get('X-LinPlayer-Key');
      if (got !== required) {
        return new Response(JSON.stringify({ error: 'unauthorized' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json', ...corsHeaders() },
        });
      }
    }
  }

  const res = await next();
  const out = new Response(res.body, res);
  for (const [k, v] of Object.entries(corsHeaders())) {
    out.headers.set(k, v);
  }
  return out;
}
