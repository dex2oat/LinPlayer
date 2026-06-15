// POST /api/trakt/token   body: { device_code }
// 轮询设备码换令牌。注入 client_secret，并原样透传上游状态码
// （客户端依赖 400=待授权 / 409 / 410=过期 / 418=拒绝 / 429=过快）。
export async function onRequestPost({ env, request }) {
  const input = await request.json().catch(() => ({}));
  const deviceCode = input.device_code;
  if (!deviceCode) {
    return new Response(JSON.stringify({ error: 'device_code required' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }
  const upstream = await fetch('https://api.trakt.tv/oauth/device/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': 'Linplayer/1.0.0',
      'trakt-api-version': '2',
      'trakt-api-key': env.TRAKT_CLIENT_ID,
    },
    body: JSON.stringify({
      code: deviceCode,
      client_id: env.TRAKT_CLIENT_ID,
      client_secret: env.TRAKT_CLIENT_SECRET,
    }),
  });
  const body = await upstream.text();
  return new Response(body, {
    status: upstream.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
