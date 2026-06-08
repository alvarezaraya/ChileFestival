#!/usr/bin/env python3
"""
Resuelve los appleMusicArtistID nulos de festivals.json usando la Apple Music API.

Solo necesita un *developer token* (no token de usuario), así que corre headless
en GitHub Actions. Los IDs de artista son globales: resolver en storefront "cl"
da un ID reutilizable en cualquier tienda.

Requisitos:
    pip install pyjwt cryptography requests

Variables de entorno (desde tu MusicKit Key en developer.apple.com → Keys):
    APPLE_TEAM_ID         Team ID (10 chars)
    APPLE_KEY_ID          Key ID de la llave MusicKit (10 chars)
    APPLE_PRIVATE_KEY     Ruta al archivo .p8

Uso:
    python resolve_apple_music_ids.py festivals.json            # interactivo
    python resolve_apple_music_ids.py festivals.json --auto     # acepta matches exactos
"""

import argparse
import difflib
import json
import os
import sys
import time
import unicodedata

import jwt
import requests

API = "https://api.music.apple.com/v1/catalog"


def make_developer_token() -> str:
    team_id = os.environ["APPLE_TEAM_ID"]
    key_id = os.environ["APPLE_KEY_ID"]
    key_path = os.environ["APPLE_PRIVATE_KEY"]
    with open(key_path, "r") as f:
        private_key = f.read()

    now = int(time.time())
    payload = {"iss": team_id, "iat": now, "exp": now + 3600}
    headers = {"alg": "ES256", "kid": key_id}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.lower()
    for ch in ",.!?:;\"'’&-":
        s = s.replace(ch, " ")
    s = s.replace(" and ", " ")
    if s.startswith("the "):
        s = s[4:]
    return " ".join(s.split())


def search_artists(session, token, storefront, name, limit):
    url = f"{API}/{storefront}/search"
    params = {"term": name, "types": "artists", "limit": limit}
    headers = {"Authorization": f"Bearer {token}"}
    for attempt in range(4):
        r = session.get(url, params=params, headers=headers, timeout=20)
        if r.status_code == 429:                # rate limited → backoff
            time.sleep(2 ** attempt)
            continue
        r.raise_for_status()
        data = r.json().get("results", {}).get("artists", {}).get("data", [])
        return [(a["id"], a["attributes"]["name"]) for a in data]
    return []


def rank(query, candidates):
    nq = normalize(query)
    scored = []
    for cid, cname in candidates:
        nc = normalize(cname)
        if nc == nq:
            score = 1.0
        else:
            ratio = difflib.SequenceMatcher(None, nq, nc).ratio()
            score = 0.9 * ratio + (0.1 if nq in nc or nc in nq else 0)
        scored.append((score, cid, cname))
    return sorted(scored, reverse=True)


def choose(artist_name, ranked, auto):
    if not ranked:
        return None
    top_score, top_id, top_name = ranked[0]
    exact = top_score >= 1.0
    unambiguous = len(ranked) == 1 or ranked[1][0] < 1.0

    if auto:
        if exact and unambiguous:
            print(f"  ✓ auto: {artist_name} → {top_name} ({top_id})")
            return top_id
        print(f"  ? auto-skip (ambiguo o sin match exacto): {artist_name}")
        return None

    print(f"\n  {artist_name!r} — candidatos:")
    for i, (sc, cid, cname) in enumerate(ranked[:5]):
        print(f"    [{i}] {cname}  (id {cid}, score {sc:.2f})")
    ans = input("    Elige número, Enter para [0], o 's' para saltar: ").strip().lower()
    if ans == "s":
        return None
    idx = int(ans) if ans.isdigit() else 0
    return ranked[idx][1] if idx < len(ranked) else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json_path")
    ap.add_argument("--storefront", default="cl")
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--auto", action="store_true",
                    help="acepta automáticamente matches exactos e inequívocos")
    args = ap.parse_args()

    token = make_developer_token()
    session = requests.Session()

    with open(args.json_path, encoding="utf-8") as f:
        feed = json.load(f)

    resolved, skipped = 0, []
    for festival in feed["festivals"]:
        for artist in festival["lineup"]:
            if artist.get("appleMusicArtistID"):
                continue
            candidates = search_artists(session, token, args.storefront,
                                        artist["name"], args.limit)
            chosen = choose(artist["name"], rank(artist["name"], candidates), args.auto)
            if chosen:
                artist["appleMusicArtistID"] = chosen
                resolved += 1
            else:
                skipped.append(f'{festival["id"]} / {artist["name"]}')
            time.sleep(0.2)                     # cortesía con la API

    # Respaldo + escritura preservando orden y acentos.
    os.replace(args.json_path, args.json_path + ".bak")
    with open(args.json_path, "w", encoding="utf-8") as f:
        json.dump(feed, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"\nResueltos: {resolved}.  Sin resolver: {len(skipped)}.")
    for s in skipped:
        print(f"  – {s}")
    if skipped:
        sys.exit(0)


if __name__ == "__main__":
    main()
