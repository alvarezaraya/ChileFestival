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
import http.client
import json
import os
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

SEARCH = "https://itunes.apple.com/search"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
ART_SIZE = "600x600cc"   # recorte cuadrado, rellena (crop-center)

# La iTunes Search API limita ~20 req/min y responde 429 cuando se la satura.
# Reintentamos con backoff exponencial (respetando Retry-After) para que un 429
# transitorio no tumbe toda la corrida.
MAX_RETRIES = 5
PAUSE = 0.5              # cortesía entre artistas (segundos)

# Artistas sin match fiable en Apple Music: NO auto-resolver (la búsqueda solo
# encuentra homónimos). Clave = `id` slug del feed. Se dejan con ID/imagen nulos
# a propósito; si algún día aparecen en el catálogo, poblar a mano.
SKIP_IDS = {
    "melania-wonder",  # único candidato era "Melania Pacheco" (score 0.62), otro artista
    "la-banda-de-la-memoria",  # gana "La Original Banda El Limón..." (score 0.51), otro artista
    "full-la-musica-de-fulano",  # gana "Fulanito", merengue dominicano (score 0.35), otro artista
    "flak",  # DJ chileno (Creamfields 2024); gana "FLAK" punk y otros homónimos rap/dance
    "isabella-serafini",  # DJ chilena (Creamfields 2024); único match es una cantante góspel
    "sepha",  # DJ chileno (Creamfields 2023); gana "Sepha." alternativo en inglés
    "blk",  # DJ hardstyle (Creamfields 2025); ganan homónimos "blk." dance y BLK rap ruso
    "lopez",  # banda chilena (Cumbre 2018); el "López" del catálogo mezcla homónimos pop
    "rulo",  # cantante chileno (Cumbre 2018); ganan un Rulo mexicano de cyphers y otros
    "chances",  # banda chilena (REC 2025); gana CHANCES, trío canadiense en francés
}

# Artistas con homónimos en Apple Music resueltos a mano: el mejor match por
# nombre es OTRO artista, así que ni --refresh debe re-resolverlos.
# Clave = `id` slug del feed; el ID/imagen correctos ya están en festivals.json.
PINNED_IDS = {
    "denver",       # dúo chileno = 2621236; la búsqueda prefiere un "Denver" urbano latino
    "panico",       # banda chilena (Kick, 2010) = 1678166227; gana un productor dance europeo
    "seamoon",      # proyecto en español = 1654057479; gana un Seamoon downtempo en inglés
    "nico-castro",  # pop/house chileno = 1639100824; gana un homónimo de puros features
    "nicole",       # pop chilena ("Esperando Nada") = 720145508; gana una Nicole new age
    "supernova",    # grupo pop chileno ("Maldito Amor") = 1529114473; gana un dúo house
    "laia",         # LAIA chilena ("Lo más bonito") = 1656577766; gana una Laia r&b en inglés
    "saiko",        # banda chilena ("Informe Saiko") = 1628094763; gana el SAIKO urbano español
    "criminal",     # thrash chileno ("Fear Itself") = 184204410; gana un rapero homónimo
}


def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    for ch in ",.!?:;\"'’&-":
        s = s.replace(ch, " ")
    s = s.replace(" and ", " ")
    return " ".join(s.split())


def get(url: str, retries: int = MAX_RETRIES) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    delay = 2.0
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            # 429 (rate limit) y 5xx (errores del servidor) son transitorios.
            if e.code != 429 and not (500 <= e.code < 600):
                raise
            if attempt >= retries:
                raise
            wait = delay
            retry_after = e.headers.get("Retry-After") if e.headers else None
            if retry_after:
                try:
                    wait = max(wait, float(retry_after))
                except ValueError:
                    pass
            print(f"    … HTTP {e.code}; reintento en {wait:.0f}s "
                  f"({attempt + 1}/{retries})")
            time.sleep(wait)
            delay = min(delay * 2, 60)
        except (urllib.error.URLError, http.client.HTTPException,
                TimeoutError) as e:
            if attempt >= retries:
                raise
            print(f"    … error de red ({e}); reintento en {delay:.0f}s "
                  f"({attempt + 1}/{retries})")
            time.sleep(delay)
            delay = min(delay * 2, 60)
    raise RuntimeError(f"agotados los reintentos para {url}")  # inalcanzable


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
    # Artistas sin foto en el catálogo devuelven el logo genérico de Apple
    # Music como og:image; eso no es un retrato y en la app se ve peor que
    # las iniciales de respaldo.
    if "/assets/meta/" in raw:
        return None
    # Normaliza el tamaño/recorte al final de la plantilla mzstatic.
    return re.sub(r"/\d+x\d+[a-z]*\.(png|jpg|jpeg)", f"/{ART_SIZE}.png", raw)


def resolve(artist, refresh):
    name = artist["name"]
    if artist.get("id") in SKIP_IDS:
        print(f"  ⊘ omitido (sin match fiable): {name}")
        return False
    if artist.get("id") in PINNED_IDS:
        print(f"  ⊙ fijado a mano (homónimo): {name}")
        return False
    have_id = bool(artist.get("appleMusicArtistID"))
    have_img = bool(artist.get("imageURL"))
    if have_id and have_img and not refresh:
        return False

    try:
        candidates = search_artists(name)
    except Exception as e:                            # noqa: BLE001
        # Tras agotar los reintentos seguimos con el resto: lo ya resuelto se
        # conserva y este artista se reintenta en la próxima corrida.
        print(f"  ! búsqueda falló para {name}: {e}")
        return False
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
            time.sleep(PAUSE)                         # cortesía con la API

    if changed:
        os.replace(args.json_path, args.json_path + ".bak")
        with open(args.json_path, "w", encoding="utf-8") as f:
            json.dump(feed, f, ensure_ascii=False, indent=2)
            f.write("\n")
    print(f"\nActualizados {changed} artistas." if changed else "\nSin cambios.")


if __name__ == "__main__":
    main()
