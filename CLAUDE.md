# Festival — notas del proyecto

## Contexto clave
- **El dueño tiene cuenta de Apple Developer.** Por lo tanto:
  - Para reproducción completa y top songs en runtime, el App ID (`cl.alvarezaraya.Festival`) necesita el servicio **MusicKit** habilitado desde el portal (Certificates, Identifiers & Profiles → Identifiers → App ID → pestaña App Services) — no se agrega desde Xcode Signing & Capabilities, MusicKit no aparece ahí.
  - Para el pipeline de datos existen dos resolvers:
    - `scripts/resolve_artist_images.py` — **token-free** (iTunes Search API + og:image). Recomendado, trae IDs + fotos, no requiere secrets.
    - `scripts/resolve_apple_music_ids.py` — usa la Apple Music API real; requiere `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` (ruta al `.p8`, no el contenido). El `.p8` sale de un **Media ID** separado del App ID de la app (Identifiers → Media IDs → habilitar MusicKit → luego Keys → asociar la key a ese Media ID). Resuelve IDs y también `accentColorHex` por artista (via `artwork.bgColor` del catálogo); sin fotos. Key del dueño ya generada, guardada fuera del repo en `~/.secrets/festival/`.
- **La app es 100 % local en datos propios**: no hay feed remoto en GitHub raw ni workflow de Actions (se eliminaron a propósito — decisión del dueño de no depender de su propia nube). `FestivalLoader` solo carga el `festivals.json` del bundle; los datos se actualizan corriendo el pipeline localmente y shippeando una nueva versión de la app. Lo único vivo en runtime son APIs oficiales de Apple (MusicKit + CDN mzstatic). No reintroducir `loadRemote`/feeds remotos sin preguntar.
- `festivals.json` (raíz) es la copia de trabajo del pipeline; la que usa la app es la espejo `Festival/festivals.json` (bundle). Mantener ambas en sync.
- **Fotos de artista en runtime:** las burbujas resuelven la foto oficial del catálogo de Apple Music en vivo (`LiveArtistArtwork` en `ArtistDetailView.swift`; requiere `appleMusicArtistID` en el feed + autorización ya concedida) y usan la `imageURL` del feed como respaldo (offline / sin autorización / artista sin ID). Las `imageURL` del feed siguen siendo necesarias como fallback — el pipeline debe seguir resolviéndolas.
