// POST /api/trakt/refresh   body: { refresh_token }
// 用 refresh_token 换新令牌。注入 client_secret。
export async function onRequestPost({ env, request }) {
  const input = await request.json().catch(() => ({}));
  const refreshToken = input.refresh_token;
  if (!refreshToken) {
    return new Response(JSON.stringify({ error: 'refresh_token required' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }
  const upstream = await fetch('https://api.trakt.tv/oauth/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': 'Linplayer/1.0.0',
      'trakt-api-version': '2',
      'trakt-api-key': env.TRAKT_CLIENT_ID,
    },
    body: JSON.stringify({
      refresh_token: refreshToken,
      client_id: env.TRAKT_CLIENT_ID,
      client_secret: env.TRAKT_CLIENT_SECRET,
      redirect_uri: 'urn:ietf:wg:oauth:2.0:oob',
      grant_type: 'refresh_token',
    }),
  });
  const body = await upstream.text();
  return new Response(body, {
    status: upstream.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
