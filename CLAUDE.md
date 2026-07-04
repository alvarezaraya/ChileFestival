# Festival — notas del proyecto

## Contexto clave
- **El dueño tiene cuenta de Apple Developer.** Por lo tanto:
  - Para reproducción completa y top songs en runtime, el App ID (`cl.alvarezaraya.Festival`) necesita el servicio **MusicKit** habilitado desde el portal (Certificates, Identifiers & Profiles → Identifiers → App ID → pestaña App Services) — no se agrega desde Xcode Signing & Capabilities, MusicKit no aparece ahí.
  - Para el pipeline de datos existen dos resolvers:
    - `scripts/resolve_artist_images.py` — **token-free** (iTunes Search API + og:image). Recomendado, trae IDs + fotos, no requiere secrets.
    - `scripts/resolve_apple_music_ids.py` — usa la Apple Music API real; requiere `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` (ruta al `.p8`, no el contenido). El `.p8` sale de un **Media ID** separado del App ID de la app (Identifiers → Media IDs → habilitar MusicKit → luego Keys → asociar la key a ese Media ID). Resuelve IDs y también `accentColorHex` por artista (via `artwork.bgColor` del catálogo); sin fotos. Key del dueño ya generada, guardada fuera del repo en `~/.secrets/festival/`.
- `festivals.json` (raíz) es el feed canónico; hay copia espejo en `Festival/festivals.json` para el bundle/offline. Mantener ambas en sync.
