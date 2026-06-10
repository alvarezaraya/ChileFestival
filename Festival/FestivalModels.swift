import Foundation
import SwiftUI

// MARK: - Feed (raíz del festivals.json alojado en GitHub)

struct FestivalFeed: Codable {
    let version: Int
    let updatedAt: Date
    let festivals: [Festival]
}

// MARK: - Festival

struct Festival: Codable, Identifiable, Hashable, Sendable {
    let id: String              // slug estable: "lollapalooza-chile-2026"
    let name: String            // "Lollapalooza Chile"
    let edition: String?        // "2026"
    let venue: String
    let city: String
    let region: String
    let dates: [Date]           // una entrada por día de festival
    let accentColorHex: String  // "#E4002B"  (tema de la vista horizontal)
    let posterImageURL: URL?
    let lineup: [LineupArtist]

    var dayCount: Int { dates.count }
    var accentColor: Color { Color(hex: accentColorHex) }

    // MARK: Estado temporal

    var startDate: Date { dates.first ?? .distantPast }
    var endDate: Date   { dates.last  ?? .distantPast }

    /// True cuando la última jornada ya terminó (midnight Santiago + 24 h).
    var isPast: Bool     { Date() >= endDate.addingTimeInterval(86_400) }
    /// True cuando el festival ya arrancó pero aún no terminó.
    var isOngoing: Bool  { !isPast && startDate <= Date() }
    /// True cuando todavía no empieza.
    var isUpcoming: Bool { startDate > Date() }

    /// Días enteros hasta el comienzo (negativo si ya pasó).
    var daysUntilStart: Int {
        let cal = Festival.santiagoCal
        return cal.dateComponents([.day],
            from: cal.startOfDay(for: Date()),
            to:   cal.startOfDay(for: startDate)).day ?? 0
    }

    /// Etiqueta compacta del rango de fechas, p. ej. "7–8 nov '25" / "24–25 oct".
    var dateRangeLabel: String {
        guard let first = dates.first else { return "" }
        let last = dates.last ?? first
        let cal  = Festival.santiagoCal
        let df   = DateFormatter()
        df.locale   = Locale(identifier: "es_CL")
        df.timeZone = TimeZone(identifier: "America/Santiago")

        let currentYear = cal.component(.year, from: Date())
        let festYear    = cal.component(.year, from: first)
        let yearSuffix  = festYear != currentYear ? " '\(festYear % 100)" : ""

        df.dateFormat = "d";  let d1 = df.string(from: first); let d2 = df.string(from: last)
        df.dateFormat = "MMM"; let m1 = df.string(from: first); let m2 = df.string(from: last)

        if dates.count == 1        { return "\(d1) \(m1)\(yearSuffix)" }
        if cal.component(.month, from: first) == cal.component(.month, from: last) {
            return "\(d1)–\(d2) \(m1)\(yearSuffix)"
        }
        return "\(d1) \(m1) – \(d2) \(m2)\(yearSuffix)"
    }

    private static let santiagoCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago") ?? .current
        c.locale   = Locale(identifier: "es_CL")
        return c
    }()

    // MARK: Artistas

    /// Artistas de un día concreto (1-indexed). Los `day == nil`
    /// (aún sin confirmar) se incluyen siempre.
    func artists(onDay day: Int? = nil) -> [LineupArtist] {
        guard let day else { return lineup }
        return lineup.filter { $0.day == day || $0.day == nil }
    }

    /// Lineup ordenado para el cúmulo: primero los pesos grandes.
    var clusterOrdered: [LineupArtist] {
        lineup.sorted { $0.billingWeight > $1.billingWeight }
    }

    /// True cuando al menos un artista tiene día asignado, es decir, hay un
    /// desglose real por jornada. Cuando es `false` (lineup vacío, o con
    /// artistas pero aún sin repartir por día) el selector de día no aporta
    /// nada y se oculta.
    var hasDayBreakdown: Bool { lineup.contains { $0.day != nil } }

    /// Artistas que se muestran en la **portada** (silueta colapsada): solo las
    /// cabezas de cartel y los estelares. Los intermedios y el resto siguen en la
    /// misma simulación —invisibles en la portada— y aparecen en sus anillos al
    /// expandir, conservando su posición. Orden por peso (cabezas de cartel
    /// primero) para que la física las ubique del centro hacia afuera.
    ///
    /// Excepciones para no dejar la portada vacía:
    /// - Cartel chico (menos de 10 artistas): se muestran todos.
    /// - Sin ningún tier alto: cae a todo el lineup.
    func headlineArtists(onDay day: Int? = nil) -> [LineupArtist] {
        let pool = artists(onDay: day).sorted { $0.billingWeight > $1.billingWeight }
        guard pool.count >= 10 else { return pool }
        let featured = pool.filter { $0.tier == .headliner || $0.tier == .main }
        return featured.isEmpty ? pool : featured
    }
}

// MARK: - LineupArtist
// (Se llama LineupArtist para no chocar con MusicKit.Artist.)

struct LineupArtist: Codable, Identifiable, Hashable, Sendable {
    let id: String                  // slug: "tyler-the-creator"
    let name: String
    let tier: Tier
    let day: Int?                   // día 1-indexed; nil = sin confirmar
    let genres: [String]
    let appleMusicArtistID: String? // resuelto UNA vez y cacheado aquí; nil = pendiente
    /// IDs extra de Apple Music cuando la entrada agrupa a más de un artista
    /// (p. ej. "Álvaro Henríquez con Pettinellis"): sus top songs se combinan
    /// con las del `appleMusicArtistID` principal. Opcional/ausente en el feed.
    let additionalAppleMusicArtistIDs: [String]?
    let setlistfmMBID: String?      // MusicBrainz id (orden por set en vivo, a futuro)
    let imageURL: URL?
    let accentColorHex: String?     // override opcional por artista

    /// Tamaño relativo del círculo en el packing.
    var billingWeight: Double { tier.weight }

    var accentColor: Color? { accentColorHex.map(Color.init(hex:)) }

    /// True cuando todavía hay que resolver el match en Apple Music.
    var needsAppleMusicResolution: Bool { appleMusicArtistID == nil }

    /// Todos los IDs de catálogo a combinar (principal + adicionales), sin
    /// nil ni duplicados, preservando el orden (principal primero).
    var appleMusicArtistIDs: [String] {
        var ids: [String] = []
        if let primary = appleMusicArtistID { ids.append(primary) }
        for extra in additionalAppleMusicArtistIDs ?? [] where !ids.contains(extra) {
            ids.append(extra)
        }
        return ids
    }
}

// MARK: - Tier

enum Tier: String, Codable, CaseIterable, Sendable {
    case headliner, main, mid, emerging

    /// Peso usado como radio base en el circle-packing.
    var weight: Double {
        switch self {
        case .headliner: 1.0
        case .main:      0.66
        case .mid:       0.42
        case .emerging:  0.28
        }
    }

    /// Nombre legible para la UI.
    var displayName: String {
        switch self {
        case .headliner: "Cabeza de cartel"
        case .main:      "Estelar"
        case .mid:       "Intermedio"
        case .emerging:  "Emergente"
        }
    }
}

// MARK: - Backfill (rellena con el bundle lo que el remoto traiga incompleto)
//
// El feed remoto es la fuente de verdad, pero puede ir por detrás del bundle
// curado (p. ej. fotos/IDs de Apple Music ya resueltos localmente y aún no
// pusheados). Sin esto, el refresco remoto "borraría" esas fotos en runtime.
// El backfill empareja por id de festival y de artista y solo rellena campos
// nulos; nunca sobrescribe datos que el remoto sí trae.

extension FestivalFeed {
    func backfilled(from fallback: FestivalFeed) -> FestivalFeed {
        let byID = Dictionary(fallback.festivals.map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        let merged = festivals.map { fest in
            byID[fest.id].map(fest.backfilled(from:)) ?? fest
        }
        return FestivalFeed(version: version, updatedAt: updatedAt, festivals: merged)
    }
}

extension Festival {
    func backfilled(from fallback: Festival) -> Festival {
        let byID = Dictionary(fallback.lineup.map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        let mergedLineup = lineup.map { artist in
            byID[artist.id].map(artist.backfilled(from:)) ?? artist
        }
        return Festival(id: id, name: name, edition: edition, venue: venue, city: city,
                        region: region, dates: dates, accentColorHex: accentColorHex,
                        posterImageURL: posterImageURL, lineup: mergedLineup)
    }
}

extension LineupArtist {
    func backfilled(from fallback: LineupArtist) -> LineupArtist {
        LineupArtist(
            id: id, name: name, tier: tier, day: day, genres: genres,
            appleMusicArtistID: appleMusicArtistID ?? fallback.appleMusicArtistID,
            additionalAppleMusicArtistIDs: additionalAppleMusicArtistIDs
                ?? fallback.additionalAppleMusicArtistIDs,
            setlistfmMBID: setlistfmMBID ?? fallback.setlistfmMBID,
            imageURL: imageURL ?? fallback.imageURL,
            accentColorHex: accentColorHex ?? fallback.accentColorHex)
    }
}

// MARK: - Loader (patrón Plaza: bundle offline + remoto en GitHub)

enum FestivalLoader {

    /// Apunta esto a tu raw de GitHub una vez que subas el JSON.
    static let feedURL = URL(string:
        "https://raw.githubusercontent.com/alvarezaraya/ChileFestival/main/festivals.json")!

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Santiago")
        formatter.dateFormat = "yyyy-MM-dd"
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }

    /// Copia incluida en el bundle: arranque instantáneo y modo offline.
    static func loadBundled() throws -> FestivalFeed {
        guard let url = Bundle.main.url(forResource: "festivals", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try makeDecoder().decode(FestivalFeed.self, from: data)
    }

    /// Remoto desde GitHub. Lanza error si falla (sin fallback interno).
    static func loadRemote() async throws -> FestivalFeed {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        let (data, _) = try await URLSession(configuration: config).data(from: feedURL)
        return try makeDecoder().decode(FestivalFeed.self, from: data)
    }
}

// MARK: - Color(hex:)

extension Color {
    /// Acepta `#RGB`, `#RRGGBB` y `#RRGGBBAA` (con o sin `#`). Si el string no
    /// es un hex válido cae a un gris neutro en vez de pintar negro en silencio
    /// —así un accentColorHex mal tecleado en el feed se nota y no desaparece
    /// sobre el fondo oscuro de la app.
    nonisolated init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&v) else { self = .gray; return }

        let r, g, b, a: Double
        switch s.count {
        case 3:   // RGB (4 bits por canal → se expande a 8)
            r = Double((v >> 8) & 0xF) / 15
            g = Double((v >> 4) & 0xF) / 15
            b = Double(v & 0xF) / 15
            a = 1
        case 6:   // RRGGBB
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        case 8:   // RRGGBBAA
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        default:
            self = .gray; return
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Nota sobre SwiftData
//
// El feed conviene mantenerlo como Codable en memoria, refrescado desde
// remoto. Si quieres favoritos / "voy a ir" / offline robusto, espeja a un
// @Model SwiftData (FavoriteFestival con el slug como clave) en vez de
// persistir todo el catálogo, que cambia con cada anuncio.
