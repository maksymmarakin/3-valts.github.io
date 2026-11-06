// Supabase Edge Function: пошук треків у YouTube Data API v3
// Deploy: supabase functions deploy music-search
// Key: YOUTUBE_API_KEY в secrets (.env -> supabase secrets set --env-file .env)
// GET /functions/v1/music-search?q=...  -> {results: [{title, artist, album, year, length, coverUrl, source}]}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'apikey, authorization, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

const YT_KEY = Deno.env.get('YOUTUBE_API_KEY') || '';

async function searchYouTube(q, limit = 8) {
  if (!YT_KEY) return [];
  const res = await fetch(
    `https://www.googleapis.com/youtube/v3/search?part=snippet&type=video&maxResults=${limit}&q=${encodeURIComponent(q)}&key=${YT_KEY}`
  );
  if (!res.ok) throw new Error('YouTube HTTP ' + res.status);
  const data = await res.json();
  return (data.items || []).map(it => ({
    title: (it.snippet?.title || '').replace(/\s*[-–|]\s*YouTube\s*$/i, ''),
    artist: it.snippet?.channelTitle || '',
    album: '',
    year: (it.snippet?.publishedAt || '').slice(0, 4),
    length: '',
    coverUrl: it.snippet?.thumbnails?.medium?.url || it.snippet?.thumbnails?.default?.url || '',
    videoId: it.id?.videoId || '',
    source: 'YouTube',
  }));
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  try {
    const url = new URL(req.url);
    const q = (url.searchParams.get('q') || '').trim();
    if (q.length < 2) {
      return new Response(JSON.stringify({ results: [] }), {
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }
    const results = await searchYouTube(q).catch(() => []);
    return new Response(JSON.stringify({ results }), {
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});
