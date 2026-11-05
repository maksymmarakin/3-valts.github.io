#!/usr/bin/env python3
"""
Міграція data/db.json -> Supabase.

Використання:
  SUPABASE_URL=https://xxxx.supabase.co \
  SUPABASE_SERVICE_KEY=eyJ... \
  python3 scripts/migrate.py

Service key береться в Supabase Dashboard -> Project Settings -> API
(Service role secret). НЕ публікувати його на сайті.
"""
import base64
import json
import os
import sys
import urllib.request
import urllib.error
import uuid
from collections import defaultdict

DB_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "db.json")
COVERS_BUCKET = "covers"

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")

if not SUPABASE_URL or not SERVICE_KEY:
    sys.exit("Потрібні env-змінні SUPABASE_URL і SUPABASE_SERVICE_KEY")

HEADERS = {
    "apikey": SERVICE_KEY,
    "Authorization": f"Bearer {SERVICE_KEY}",
    "Content-Type": "application/json",
    "Prefer": "return=representation",
}


def request(method, path, body=None, raw=False):
    url = f"{SUPABASE_URL}{path}"
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            payload = resp.read()
            return payload if raw else json.loads(payload or b"null")
    except urllib.error.HTTPError as e:
        print(f"  ! HTTP {e.code} {method} {path}: {e.read().decode()[:500]}", file=sys.stderr)
        raise


def upload_cover(track_key, data_url):
    """Завантажує base64-обкладинку в Storage, повертає публічний URL."""
    if not data_url or not data_url.startswith("data:"):
        return None
    try:
        header, b64 = data_url.split(",", 1)
        mime = header.split(":")[1].split(";")[0]
        ext = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
               "image/gif": "gif"}.get(mime, "jpg")
        blob = base64.b64decode(b64)
    except Exception:
        return None

    obj_path = f"{track_key}.{ext}"
    url = f"{SUPABASE_URL}/storage/v1/object/{COVERS_BUCKET}/{obj_path}"
    req = urllib.request.Request(
        url, data=blob, method="POST",
        headers={
            "apikey": SERVICE_KEY,
            "Authorization": f"Bearer {SERVICE_KEY}",
            "Content-Type": mime,
            "x-upsert": "true",
        },
    )
    try:
        with urllib.request.urlopen(req):
            pass
    except urllib.error.HTTPError as e:
        print(f"  ! cover upload {obj_path}: HTTP {e.code} {e.read().decode()[:200]}", file=sys.stderr)
        return None
    return f"{SUPABASE_URL}/storage/v1/object/public/{COVERS_BUCKET}/{obj_path}"


def main():
    with open(DB_PATH) as f:
        db = json.load(f)

    # 1. Evaluators
    print(f"Міграція {len(db.get('evaluators', []))} оцінювачів...")
    evaluator_ids = {}  # name -> uuid
    for ev in db.get("evaluators", []):
        avatar_url = None
        if ev.get("avatarBase64", "").startswith("data:"):
            avatar_url = upload_cover(f"avatars/{uuid.uuid4()}", ev["avatarBase64"])
        row = request("POST", "/rest/v1/evaluators",
                      {"name": ev.get("name", ""), "avatar_url": avatar_url})
        evaluator_ids[ev.get("name", "")] = row[0]["id"]
        print(f"  + {ev.get('name')}")

    # 2. History -> tracks + sessions + ratings
    history = db.get("history", [])
    print(f"Міграція {len(history)} оцінених треків...")

    # Групуємо записи в сесії за timestamp
    sessions_by_ts = defaultdict(list)
    for entry in history:
        sessions_by_ts[entry.get("timestamp", "")].append(entry)

    migrated = 0
    for ts, entries in sessions_by_ts.items():
        session = request("POST", "/rest/v1/sessions", {"created_at": ts})
        session_id = session[0]["id"]

        for entry in entries:
            cover_url = upload_cover(f"tracks/{entry['trackId']}", entry.get("coverBase64"))
            track = request("POST", "/rest/v1/tracks", {
                "title": entry.get("title", ""),
                "artist": entry.get("artist", ""),
                "cover_url": cover_url,
                "year": entry.get("year"),
                "length": entry.get("length"),
                "lyrics": entry.get("lyrics"),
                "created_at": ts,
            })
            track_id = track[0]["id"]

            ratings = []
            for score in entry.get("evaluatorScores", []):
                name = score.get("name", "")
                if not name or name not in evaluator_ids:
                    continue
                if score.get("vibe") is None:
                    continue
                ratings.append({
                    "session_id": session_id,
                    "track_id": track_id,
                    "evaluator_id": evaluator_ids[name],
                    "vibe": score.get("vibe"),
                    "text": score.get("text"),
                    "beat": score.get("beat"),
                })
            if ratings:
                request("POST", "/rest/v1/ratings", ratings)
            migrated += 1
            if migrated % 10 == 0:
                print(f"  ...{migrated}/{len(history)}")

    print(f"Готово: {migrated} треків, {len(sessions_by_ts)} сесій.")


if __name__ == "__main__":
    main()
