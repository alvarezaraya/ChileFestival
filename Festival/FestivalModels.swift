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
        var df   = DateFormatter()
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
    let setlistfmMBID: String?      // MusicBrainz id (orden por set en vivo, a futuro)
    let imageURL: URL?
    let accentColorHex: String?     // override opcional por artista

    /// Tamaño relativo del círculo en el packing.
    var billingWeight: Double { tier.weight }

    var accentColor: Color? { accentColorHex.map(Color.init(hex:)) }

    /// True cuando todavía hay que resolver el match en Apple Music.
    var needsAppleMusicResolution: Bool { appleMusicArtistID == nil }
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
    nonisolated init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Nota sobre SwiftData
//
// El feed conviene mantenerlo como Codable en memoria, refrescado desde
// remoto. Si quieres favoritos / "voy a ir" / offline robusto, espeja a un
// @Model SwiftData (FavoriteFestival con el slug como clave) en vez de
// persistir todo el catálogo, que cambia con cada anuncio.
