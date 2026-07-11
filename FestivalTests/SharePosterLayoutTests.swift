import CoreGraphics
import Foundation
import Testing
@testable import Festival

// MARK: - Packing estático del póster
//
// SharePosterLayout es determinista a propósito (sin azar): estas invariantes
// son las que garantizan que el póster compartido siempre salga bien armado.

@Suite struct SharePosterLayoutTests {

    private let region = FestivalShareCard.clusterRegion

    @Test func cartelVacioNoRevienta() {
        #expect(SharePosterLayout.pack([], in: region).isEmpty)
    }

    @Test func conservaTodosLosArtistas() {
        let artists = Fixtures.lineup(count: 24)
        let placed = SharePosterLayout.pack(artists, in: region)
        #expect(placed.map(\.artist.id) == artists.map(\.id))
    }

    @Test func esDeterminista() {
        let artists = Fixtures.lineup(count: 18)
        let a = SharePosterLayout.pack(artists, in: region)
        let b = SharePosterLayout.pack(artists, in: region)
        for (x, y) in zip(a, b) {
            #expect(x.center == y.center)
            #expect(x.radius == y.radius)
        }
    }

    @Test(arguments: [1, 5, 10, 24])
    func sinSolapesVisibles(count: Int) {
        let placed = SharePosterLayout.pack(Fixtures.lineup(count: count), in: region)
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                let d = hypot(placed[j].center.x - placed[i].center.x,
                              placed[j].center.y - placed[i].center.y)
                let minD = placed[i].radius + placed[j].radius
                // Tolerancia de 1 pt: la relajación es finita; un solape
                // subpixel no se ve, uno mayor sí.
                #expect(d >= minD - 1.0,
                        "solape entre \(placed[i].artist.id) y \(placed[j].artist.id)")
            }
        }
    }

    @Test(arguments: [1, 10, 24])
    func todosDentroDeLaZona(count: Int) {
        let placed = SharePosterLayout.pack(Fixtures.lineup(count: count), in: region)
        for p in placed {
            #expect(p.center.x - p.radius >= region.minX - 0.5)
            #expect(p.center.x + p.radius <= region.maxX + 0.5)
            #expect(p.center.y - p.radius >= region.minY - 0.5)
            #expect(p.center.y + p.radius <= region.maxY + 0.5)
        }
    }

    @Test func lasCabezasDeCartelSonMasGrandes() {
        let placed = SharePosterLayout.pack(Fixtures.lineup(count: 12), in: region)
        let headliner = placed.first { $0.artist.tier == .headliner }!
        let mid = placed.first { $0.artist.tier == .mid }!
        #expect(headliner.radius > mid.radius)
    }
}
