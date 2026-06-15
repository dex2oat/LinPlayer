// POST /api/trakt/device
// 申请 Trakt 设备码。只需 client_id（非机密），但放到代理可让客户端完全不持有凭据。
export async function onRequestPost({ env }) {
  const upstream = await fetch('https://api.trakt.tv/oauth/device/code', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': 'Linplayer/1.0.0',
      'trakt-api-version': '2',
      'trakt-api-key': env.TRAKT_CLIENT_ID,
    },
    body: JSON.stringify({ client_id: env.TRAKT_CLIENT_ID }),
  });
  const body = await upstream.text();
  return new Response(body, {
    status: upstream.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
