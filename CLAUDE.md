# Festival — notas del proyecto

## Contexto clave
- **El dueño tiene cuenta de Apple Developer.** Por lo tanto:
  - Se puede activar la capability **MusicKit** (Signing & Capabilities) y registrar el App ID → habilita reproducción completa y top songs en runtime.
  - Para el pipeline de datos existen dos resolvers:
    - `scripts/resolve_artist_images.py` — **token-free** (iTunes Search API + og:image). Recomendado, trae IDs + fotos, no requiere secrets.
    - `scripts/resolve_apple_music_ids.py` — usa la Apple Music API con **MusicKit Key (.p8)**; requiere `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY_P8`. Solo IDs (sin fotos).
- `festivals.json` (raíz) es el feed canónico; hay copia espejo en `Festival/festivals.json` para el bundle/offline. Mantener ambas en sync.
