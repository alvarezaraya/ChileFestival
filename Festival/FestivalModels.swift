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

    /// Remoto desde GitHub. Si falla, cae al bundle.
    static func loadRemote() async throws -> FestivalFeed {
        do {
            let (data, _) = try await URLSession.shared.data(from: feedURL)
            return try makeDecoder().decode(FestivalFeed.self, from: data)
        } catch {
            return try loadBundled()
        }
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
