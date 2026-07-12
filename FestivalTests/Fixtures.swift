import Foundation
@testable import Festival

// MARK: - Fixtures compartidas
//
// Los tests construyen festivales sintéticos con la misma convención que el
// feed real: fechas a medianoche de Santiago (así se decodifican en
// FestivalLoader) e ids con sufijo de año.

enum Fixtures {

    static let santiago: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        return c
    }()

    /// Medianoche de Santiago del día pedido, como en el feed.
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        santiago.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func artist(_ id: String, tier: Tier = .mid, day: Int? = nil,
                       imageURL: URL? = nil) -> LineupArtist {
        LineupArtist(id: id, name: id.replacingOccurrences(of: "-", with: " "),
                     tier: tier, day: day, genres: [],
                     appleMusicArtistID: nil, additionalAppleMusicArtistIDs: nil,
                     setlistfmMBID: nil, imageURL: imageURL, accentColorHex: nil)
    }

    static func festival(id: String, name: String = "Fest",
                         dates: [Date], lineup: [LineupArtist] = [],
                         attendance: Int? = nil) -> Festival {
        Festival(id: id, name: name, edition: nil,
                 venue: "Parque", city: "Santiago", region: "RM",
                 dates: dates, accentColorHex: "#E4002B",
                 posterImageURL: nil, websiteURL: nil,
                 attendance: attendance, lineup: lineup)
    }

    /// Cartel variado: 2 cabezas de cartel, 3 estelares, resto intermedios.
    static func lineup(count: Int) -> [LineupArtist] {
        (0..<count).map { i in
            let tier: Tier = i < 2 ? .headliner : (i < 5 ? .main : .mid)
            return artist("artista-\(i)", tier: tier, day: i % 2 + 1)
        }
    }
}
