// Supabase Edge Function: проксі для Genius/YouTube (обходить CORS)
// Deploy: supabase functions deploy genius-proxy
// GET  /functions/v1/genius-proxy?url=https://...  — GET-проксі
// POST /functions/v1/genius-proxy  body: {"url":"...","body":{...}} — POST-проксі

const ALLOWED_HOSTS = ['genius.com', 'www.genius.com', 'youtube.com', 'www.youtube.com', 'music.youtube.com', 'youtu.be', 'youtubei.googleapis.com'];

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'apikey, authorization, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

function withCors(res) {
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries(CORS_HEADERS)) headers.set(k, v);
  return new Response(res.body, { status: res.status, headers });
}

function isAllowed(target) {
  try {
    const parsed = new URL(target);
    return ALLOWED_HOSTS.some(h => parsed.hostname === h || parsed.hostname.endsWith('.' + h));
  } catch (e) { return false; }
}

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  try {
    if (req.method === 'POST') {
      const { url: target, body } = await req.json();
      if (!target || !isAllowed(target)) {
        return withCors(new Response('Bad or disallowed url', { status: 400 }));
      }
      const res = await fetch(target, {
        method: 'POST',
        headers: {
          'User-Agent': UA,
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/'
        },
        body: JSON.stringify(body || {})
      });
      const text = await res.text();
      return withCors(new Response(text, {
        headers: { 'Content-Type': res.headers.get('Content-Type') || 'application/json' }
      }));
    }

    // GET
    const url = new URL(req.url);
    const target = url.searchParams.get('url');
    if (!target) return withCors(new Response('Missing ?url=', { status: 400 }));
    if (!isAllowed(target)) return withCors(new Response('Host not allowed', { status: 403 }));

    const res = await fetch(target, {
      headers: { 'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml' },
      redirect: 'follow'
    });
    const html = await res.text();
    return withCors(new Response(html, {
      headers: { 'Content-Type': 'text/html; charset=utf-8' }
    }));
  } catch (e) {
    return withCors(new Response('Fetch failed: ' + e.message, { status: 502 }));
  }
});
