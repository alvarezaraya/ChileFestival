import Combine
import Foundation
import SwiftUI

// MARK: - Serie de festival
//
// El feed trae una entrada por edición ("lollapalooza-chile-2026"), pero seguir
// un festival aplica a la marca completa: quien sigue Lollapalooza quiere ver
// todas sus ediciones (pasadas y futuras) sin re-elegirlo cada año. La serie se
// deriva del slug sin el sufijo de año, así el follow sobrevive a los feeds de
// versiones futuras de la app sin migraciones.

struct FestivalSeries: Identifiable {
    let key: String            // "lollapalooza-chile"
    let editions: [Festival]   // cronológicas (el feed ya viene ordenado)

    var id: String { key }
    var name: String { editions.last?.name ?? key }
    var latest: Festival? { editions.last }

    /// Primera edición que aún no termina (en curso o por venir).
    var nextEdition: Festival? { editions.first { !$0.isPast } }

    /// Color de la edición más relevante: la próxima si existe, si no la última.
    var accentColor: Color { (nextEdition ?? latest)?.accentColor ?? .gray }

    /// Mayor asistencia registrada entre las ediciones (0 si ninguna tiene cifra).
    var maxAttendance: Int { editions.compactMap(\.attendance).max() ?? 0 }

    /// Línea de estado para las tarjetas de selección.
    var statusLabel: String {
        if let next = nextEdition {
            return next.isOngoing
                ? "En curso · \(next.dateRangeLabel)"
                : "Próxima: \(next.dateRangeLabel)"
        }
        if let last = latest {
            return "Última edición: \(last.edition ?? last.dateRangeLabel)"
        }
        return ""
    }
}

extension Festival {
    /// Slug de la serie: el id sin el sufijo "-YYYY".
    /// "fauna-primavera-2025" → "fauna-primavera".
    var seriesKey: String {
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 4, last.allSatisfy(\.isNumber) {
            return parts.dropLast().joined(separator: "-")
        }
        return id
    }
}

extension FestivalFeed {
    /// Series únicas del feed, ordenadas para la pantalla de selección: primero
    /// las que tienen edición próxima (la más cercana arriba), después las que
    /// solo tienen ediciones pasadas (la más reciente arriba).
    var series: [FestivalSeries] {
        var byKey: [String: [Festival]] = [:]
        var order: [String] = []
        for festival in festivals {
            let key = festival.seriesKey
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(festival)
        }
        let all = order.map { FestivalSeries(key: $0, editions: byKey[$0] ?? []) }
        return all.sorted { a, b in
            switch (a.nextEdition, b.nextEdition) {
            case (let na?, let nb?): return na.startDate < nb.startDate
            case (.some, .none):     return true
            case (.none, .some):     return false
            case (.none, .none):
                return (a.latest?.endDate ?? .distantPast) > (b.latest?.endDate ?? .distantPast)
            }
        }
    }

    /// Las cinco series más multitudinarias del catálogo, medidas por la mayor
    /// asistencia registrada entre sus ediciones. Son la portada de la pantalla
    /// de selección; el resto del catálogo se alcanza con el buscador. Empates:
    /// primero la serie con edición próxima, luego orden alfabético, para que
    /// el ranking sea estable entre lanzamientos.
    var featuredSeries: [FestivalSeries] {
        let ranked = series
            .filter { $0.maxAttendance > 0 }
            .sorted { a, b in
                if a.maxAttendance != b.maxAttendance { return a.maxAttendance > b.maxAttendance }
                if (a.nextEdition != nil) != (b.nextEdition != nil) { return a.nextEdition != nil }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        return Array(ranked.prefix(5))
    }

    /// Feed reducido a las series seguidas. Si el cruce queda vacío (p. ej. un
    /// feed futuro dejó de incluir todo lo que el usuario seguía) se devuelve el
    /// feed completo: mejor mostrar de más que un carrusel vacío sin salida.
    func filtered(bySeriesKeys keys: [String]) -> FestivalFeed {
        guard !keys.isEmpty else { return self }
        let kept = festivals.filter { keys.contains($0.seriesKey) }
        guard !kept.isEmpty else { return self }
        return FestivalFeed(version: version, updatedAt: updatedAt, festivals: kept)
    }
}

// MARK: - FollowStore
//
// Persistencia mínima en UserDefaults: solo la lista de series seguidas. El
// catálogo completo sigue viviendo en el festivals.json del bundle.

@MainActor
final class FollowStore: ObservableObject {
    /// Festivales que se pueden seguir sin pagar. Desde el cuarto aparece el
    /// paywall (ver EntitlementStore).
    static let freeLimit = 3

    private static let defaultsKey = "followedSeriesKeys"

    @Published private(set) var followedKeys: [String]

    init() {
        followedKeys = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func isFollowing(_ key: String) -> Bool { followedKeys.contains(key) }

    func setFollowed(_ keys: [String]) {
        followedKeys = keys
        UserDefaults.standard.set(keys, forKey: Self.defaultsKey)
    }
}
