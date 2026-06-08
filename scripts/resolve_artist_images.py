#!/usr/bin/env python3
"""
Resuelve `appleMusicArtistID` e `imageURL` de festivals.json SIN developer token.

Usa la iTunes Search API (pública) para encontrar el artista en Apple Music
—que devuelve el `artistId` (mismo espacio de IDs que MusicKit) y la URL de su
página— y luego lee el `og:image` de esa página, que es el retrato oficial de
Apple Music (`AMCArtistImages`). La URL de mzstatic es una plantilla
redimensionable: se normaliza a un recorte cuadrado para las burbujas.

Ventaja sobre `resolve_apple_music_ids.py`: no requiere la MusicKit Key (.p8) ni
secrets, así que corre en cualquier parte. Preserva lo ya resuelto salvo --refresh.

Uso:
    python resolve_artist_images.py festivals.json
    python resolve_artist_images.py festivals.json --refresh   # re-resuelve todo
"""

import argparse
import difflib
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

SEARCH = "https://itunes.apple.com/search"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
ART_SIZE = "600x600cc"   # recorte cuadrado, rellena (crop-center)


def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    for ch in ",.!?:;\"'’&-":
        s = s.replace(ch, " ")
    s = s.replace(" and ", " ")
    return " ".join(s.split())


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read()


def search_artists(name: str, limit: int = 8):
    """Candidatos (id, nombre, link) en orden de relevancia de la API.

    Primero el entity `musicArtist`; si no aparece un buen match, cae a
    `musicTrack` (algunos artistas —p. ej. Godspeed You! Black Emperor— no
    salen en la búsqueda de artistas pero sí vía sus canciones)."""
    q = urllib.parse.urlencode({"term": name, "entity": "musicArtist", "limit": limit})
    data = json.loads(get(f"{SEARCH}?{q}").decode("utf-8", "ignore"))
    out = [(str(a["artistId"]), a["artistName"], a.get("artistLinkUrl"))
           for a in data.get("results", [])]
    if out and best_score(name, out) >= 0.6:
        return out

    q = urllib.parse.urlencode({"term": name, "entity": "musicTrack", "limit": limit})
    data = json.loads(get(f"{SEARCH}?{q}").decode("utf-8", "ignore"))
    seen, tracks = set(), []
    for a in data.get("results", []):
        aid = str(a.get("artistId"))
        if aid and aid not in seen:
            seen.add(aid)
            tracks.append((aid, a.get("artistName", ""), a.get("artistViewUrl")))
    return out + tracks


def best_score(name, candidates):
    nq = normalize(name)
    return max((1.0 if normalize(c[1]) == nq
                else difflib.SequenceMatcher(None, nq, normalize(c[1])).ratio())
               for c in candidates)


def best_match(name: str, candidates):
    nq = normalize(name)
    scored = []
    for idx, (aid, aname, link) in enumerate(candidates):
        nc = normalize(aname)
        ratio = 1.0 if nc == nq else difflib.SequenceMatcher(None, nq, nc).ratio()
        # Empates de ratio → gana el de mayor relevancia (menor índice).
        scored.append((ratio, -idx, aid, aname, link))
    scored.sort(reverse=True)
    if not scored:
        return None
    ratio, _, aid, aname, link = scored[0]
    return (ratio, aid, aname, link)


def og_image(link: str):
    html = get(link).decode("utf-8", "ignore")
    m = re.search(r'<meta property="og:image" content="([^"]+)"', html)
    if not m:
        return None
    raw = m.group(1)
    # Normaliza el tamaño/recorte al final de la plantilla mzstatic.
    return re.sub(r"/\d+x\d+[a-z]*\.(png|jpg|jpeg)", f"/{ART_SIZE}.png", raw)


def resolve(artist, refresh):
    name = artist["name"]
    have_id = bool(artist.get("appleMusicArtistID"))
    have_img = bool(artist.get("imageURL"))
    if have_id and have_img and not refresh:
        return False

    candidates = search_artists(name)
    match = best_match(name, candidates)
    if not match:
        print(f"  ? sin match: {name}")
        return False
    score, aid, aname, link = match

    changed = False
    if refresh or not have_id:
        artist["appleMusicArtistID"] = aid
        changed = True
    if link and (refresh or not have_img):
        try:
            img = og_image(link)
        except Exception as e:                       # noqa: BLE001
            img = None
            print(f"  ! og:image falló para {name}: {e}")
        if img:
            artist["imageURL"] = img
            changed = True

    flag = "✓" if changed else "·"
    print(f"  {flag} {name} → {aname} (id {aid}, score {score:.2f})")
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json_path")
    ap.add_argument("--refresh", action="store_true",
                    help="re-resuelve incluso lo ya poblado")
    args = ap.parse_args()

    with open(args.json_path, encoding="utf-8") as f:
        feed = json.load(f)

    changed = 0
    for festival in feed["festivals"]:
        print(f"\n{festival['name']}:")
        for artist in festival["lineup"]:
            if resolve(artist, args.refresh):
                changed += 1
            time.sleep(0.25)                          # cortesía con la API

    if changed:
        os.replace(args.json_path, args.json_path + ".bak")
        with open(args.json_path, "w", encoding="utf-8") as f:
            json.dump(feed, f, ensure_ascii=False, indent=2)
            f.write("\n")
    print(f"\nActualizados {changed} artistas." if changed else "\nSin cambios.")


if __name__ == "__main__":
    main()
