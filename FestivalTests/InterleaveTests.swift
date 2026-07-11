import Foundation
import Testing
@testable import Festival

// MARK: - Mezcla intercalada (round-robin del mix)

@Suite struct InterleaveTests {

    @Test func intercalaUnaDeCadaPoolPorVuelta() {
        let result = ArtistCatalog.interleave([["a1", "a2"], ["b1", "b2"], ["c1", "c2"]])
        #expect(result == ["a1", "b1", "c1", "a2", "b2", "c2"])
    }

    @Test func poolsDesparejasSeAgotanSinHuecos() {
        let result = ArtistCatalog.interleave([["a1", "a2", "a3"], ["b1"]])
        #expect(result == ["a1", "b1", "a2", "a3"])
    }

    @Test func poolVaciaNoAporta() {
        let result = ArtistCatalog.interleave([[], ["b1"], []])
        #expect(result == ["b1"])
    }

    @Test func sinPoolsDevuelveVacio() {
        #expect(ArtistCatalog.interleave([[String]]()).isEmpty)
    }

    @Test func conservaTodosLosElementos() {
        let pools = [["a1", "a2"], ["b1", "b2", "b3", "b4"], ["c1"]]
        let result = ArtistCatalog.interleave(pools)
        #expect(result.count == 7)
        #expect(Set(result) == Set(pools.flatMap { $0 }))
    }
}
