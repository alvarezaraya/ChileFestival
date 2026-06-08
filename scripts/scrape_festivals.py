#!/usr/bin/env python3
"""
Construye/actualiza festivals.json a partir de fuentes por festival.

Diseño: cada festival tiene una función scraper que devuelve un dict con la
estructura del feed. Al fusionar con el JSON existente se PRESERVAN los campos
ya resueltos (appleMusicArtistID, setlistfmMBID), para no rehacer ese trabajo
en cada corrida.

⚠️ Los scrapers de abajo son STUBS. Conecta tus parsers reales (requests +
BeautifulSoup, o el JSON de lineup del sitio oficial) antes de activar el cron,
o sobrescribirás el feed con carteles incompletos.

Requisitos: pip install requests beautifulsoup4
"""

import datetime
import json
import os
import re
import unicodedata


OUTPUT = "festivals.json"
PRESERVE = ("appleMusicArtistID", "setlistfmMBID")


def slugify(name: str) -> str:
    s = unicodedata.normalize("NFKD", name)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


def artist(name, tier, day=None, genres=None):
    return {
        "id": slugify(name),
        "name": name,
        "tier": tier,
        "day": day,
        "genres": genres or [],
        "appleMusicArtistID": None,
        "setlistfmMBID": None,
        "imageURL": None,
        "accentColorHex": None,
    }


# --- Scrapers por festival -------------------------------------------------
# Cada función devuelve un festival COMPLETO. Reemplaza el cuerpo con tu parser.

def scrape_lollapalooza():
    # TODO: parsear el lineup oficial (https://www.lollapaloozacl.com).
    return {
        "id": "lollapalooza-chile-2026",
        "name": "Lollapalooza Chile",
        "edition": "2026",
        "venue": "Parque O'Higgins",
        "city": "Santiago",
        "region": "Región Metropolitana",
        "dates": ["2026-03-13", "2026-03-14", "2026-03-15"],
        "accentColorHex": "#E4002B",
        "posterImageURL": None,
        "lineup": [
            artist("Sabrina Carpenter", "headliner", 1, ["pop"]),
            artist("Tyler, The Creator", "headliner", 2, ["hip hop"]),
            artist("Chappell Roan", "headliner", 3, ["pop"]),
            # ... completa con tu parser
        ],
    }


# def scrape_fauna_primavera(): ...


SCRAPERS = [
    scrape_lollapalooza,
    # scrape_fauna_primavera,
]


# --- Merge preservando lo ya resuelto --------------------------------------

def load_existing_index(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        feed = json.load(f)
    index = {}
    for fest in feed.get("festivals", []):
        for a in fest.get("lineup", []):
            index[(fest["id"], a["id"])] = a
    return index


def merge(festival, existing_index):
    for a in festival["lineup"]:
        prev = existing_index.get((festival["id"], a["id"]))
        if prev:
            for key in PRESERVE:
                if prev.get(key):
                    a[key] = prev[key]
    return festival


def main():
    existing = load_existing_index(OUTPUT)
    festivals = [merge(scrape(), existing) for scrape in SCRAPERS]

    feed = {
        "version": 1,
        "updatedAt": datetime.date.today().isoformat(),
        "festivals": festivals,
    }

    with open(OUTPUT, "w", encoding="utf-8") as f:
        json.dump(feed, f, ensure_ascii=False, indent=2)
        f.write("\n")

    total = sum(len(x["lineup"]) for x in festivals)
    print(f"Escrito {OUTPUT}: {len(festivals)} festivales, {total} artistas.")


if __name__ == "__main__":
    main()
