import Foundation
import Testing
import SwiftUI
@testable import Festival

// MARK: - Series (clave, filtrado, orden)

@Suite struct SeriesTests {

    @Test func seriesKeyQuitaElSufijoDeAño() {
        let f = Fixtures.festival(id: "fauna-primavera-2025",
                                  dates: [Fixtures.day(2025, 11, 7)])
        #expect(f.seriesKey == "fauna-primavera")
    }

    @Test func seriesKeySinAñoQuedaIgual() {
        let f = Fixtures.festival(id: "ruidosa-fest",
                                  dates: [Fixtures.day(2026, 3, 7)])
        #expect(f.seriesKey == "ruidosa-fest")
    }

    @Test func seriesKeyNoConfundeNumerosCortos() {
        // "en-orbita-80s" termina en dígitos pero no son un año de 4 cifras.
        let f = Fixtures.festival(id: "fiesta-80s", dates: [Fixtures.day(2026, 1, 10)])
        #expect(f.seriesKey == "fiesta-80s")
    }

    @Test func filtradoDevuelveSoloLasSeriesSeguidas() {
        let feed = FestivalFeed(version: 1, updatedAt: .now, festivals: [
            Fixtures.festival(id: "lolla-2025", dates: [Fixtures.day(2025, 3, 21)]),
            Fixtures.festival(id: "lolla-2026", dates: [Fixtures.day(2026, 3, 13)]),
            Fixtures.festival(id: "fauna-2026", dates: [Fixtures.day(2026, 11, 6)]),
        ])
        let filtered = feed.filtered(bySeriesKeys: ["lolla"])
        #expect(filtered.festivals.map(\.id) == ["lolla-2025", "lolla-2026"])
    }

    @Test func filtradoSinKeysDevuelveTodo() {
        let feed = FestivalFeed(version: 1, updatedAt: .now, festivals: [
            Fixtures.festival(id: "lolla-2026", dates: [Fixtures.day(2026, 3, 13)]),
        ])
        #expect(feed.filtered(bySeriesKeys: []).festivals.count == 1)
    }

    @Test func filtradoSinCoincidenciasCaeAlFeedCompleto() {
        // Un feed futuro que dejó de incluir lo seguido no debe dejar un
        // carrusel vacío sin salida.
        let feed = FestivalFeed(version: 1, updatedAt: .now, festivals: [
            Fixtures.festival(id: "lolla-2026", dates: [Fixtures.day(2026, 3, 13)]),
        ])
        let filtered = feed.filtered(bySeriesKeys: ["festival-desaparecido"])
        #expect(filtered.festivals.count == 1)
    }

    @Test func lasSeriesAgrupanEdicionesYOrdenanPorProximidad() {
        // "pasado" solo tiene ediciones terminadas; "proximo" tiene una futura.
        let feed = FestivalFeed(version: 1, updatedAt: .now, festivals: [
            Fixtures.festival(id: "pasado-2023", dates: [Fixtures.day(2023, 11, 11)]),
            Fixtures.festival(id: "proximo-2023", dates: [Fixtures.day(2023, 3, 17)]),
            Fixtures.festival(id: "proximo-2099", dates: [Fixtures.day(2099, 3, 13)]),
        ])
        let series = feed.series
        #expect(series.map(\.key) == ["proximo", "pasado"])
        #expect(series[0].editions.count == 2)
        #expect(series[0].nextEdition?.id == "proximo-2099")
        #expect(series[1].nextEdition == nil)
    }

    @Test func lasDestacadasSonLasCincoMasMultitudinariasSinProximas() {
        // Sin ediciones futuras, las destacadas caen a las 5 de mayor
        // asistencia; una serie sin cifra queda fuera aunque exista, y la
        // serie toma la MAYOR asistencia entre sus ediciones.
        let feed = FestivalFeed(version: 1, updatedAt: .now, festivals: [
            Fixtures.festival(id: "gigante-2024", dates: [Fixtures.day(2024, 3, 1)], attendance: 360_000),
            Fixtures.festival(id: "grande-2024", dates: [Fixtures.day(2024, 4, 1)], attendance: 240_000),
            Fixtures.festival(id: "mediano-2011", dates: [Fixtures.day(2011, 11, 1)], attendance: 100_000),
            Fixtures.festival(id: "mediano-2012", dates: [Fixtures.day(2012, 11, 1)], attendance: 70_000),
            Fixtures.festival(id: "menor-2024", dates: [Fixtures.day(2024, 5, 1)], attendance: 90_000),
            Fixtures.festival(id: "chico-2024", dates: [Fixtures.day(2024, 6, 1)], attendance: 35_000),
            Fixtures.festival(id: "sexto-2024", dates: [Fixtures.day(2024, 7, 1)], attendance: 30_000),
            Fixtures.festival(id: "sin-cifra-2024", dates: [Fixtures.day(2024, 8, 1)]),
        ])
        let featured = feed.featuredSeries
        #expect(featured.map(\.key) == ["gigante", "grande", "mediano", "menor", "chico"])
        #expect(featured.first?.maxAttendance == 360_000)
    }

    @Test func lasDestacadasMezclanGigantesYProximas() {
        // Con ediciones futuras: los 2 más multitudinarios van primero y los
        // 3 próximos más cercanos después, aunque no tengan cifra.
        let feed = FestivalFeed(version: 1, updatedAt: .now, festivals: [
            Fixtures.festival(id: "gigante-2024", dates: [Fixtures.day(2024, 3, 1)], attendance: 360_000),
            Fixtures.festival(id: "grande-2024", dates: [Fixtures.day(2024, 4, 1)], attendance: 240_000),
            Fixtures.festival(id: "mediano-2011", dates: [Fixtures.day(2011, 11, 1)], attendance: 100_000),
            Fixtures.festival(id: "prox-a-2099", dates: [Fixtures.day(2099, 1, 1)]),
            Fixtures.festival(id: "prox-b-2099", dates: [Fixtures.day(2099, 2, 1)]),
            Fixtures.festival(id: "prox-c-2099", dates: [Fixtures.day(2099, 3, 1)]),
            Fixtures.festival(id: "prox-d-2099", dates: [Fixtures.day(2099, 4, 1)]),
        ])
        #expect(feed.featuredSeries.map(\.key)
                == ["gigante", "grande", "prox-a", "prox-b", "prox-c"])
    }

    @Test func lasDestacadasRellenanCuandoUnGiganteEstaProximo() {
        // Un gigante con edición futura ocupa un solo cupo: la lista se
        // rellena con la siguiente serie por asistencia hasta llegar a 5.
        let feed = FestivalFeed(version: 1, updatedAt: .now, festivals: [
            Fixtures.festival(id: "gigante-2024", dates: [Fixtures.day(2024, 3, 1)], attendance: 360_000),
            Fixtures.festival(id: "grande-2024", dates: [Fixtures.day(2024, 4, 1)], attendance: 240_000),
            Fixtures.festival(id: "grande-2099", dates: [Fixtures.day(2099, 1, 15)], attendance: 240_000),
            Fixtures.festival(id: "mediano-2011", dates: [Fixtures.day(2011, 11, 1)], attendance: 100_000),
            Fixtures.festival(id: "chico-2024", dates: [Fixtures.day(2024, 6, 1)], attendance: 35_000),
            Fixtures.festival(id: "prox-a-2099", dates: [Fixtures.day(2099, 2, 1)]),
            Fixtures.festival(id: "prox-b-2099", dates: [Fixtures.day(2099, 3, 1)]),
        ])
        // "grande" es gigante Y próxima: aparece una vez, y "mediano" y
        // "chico" completan los 5 cupos.
        #expect(feed.featuredSeries.map(\.key)
                == ["gigante", "grande", "prox-a", "prox-b", "mediano"])
    }
}

// MARK: - Festival (días, destacados, fechas)

@Suite struct FestivalTests {

    @Test func artistasPorDiaIncluyeLosSinConfirmar() {
        let lineup = [
            Fixtures.artist("a", day: 1),
            Fixtures.artist("b", day: 2),
            Fixtures.artist("c", day: nil),   // sin confirmar
        ]
        let f = Fixtures.festival(id: "x-2026",
                                  dates: [Fixtures.day(2026, 3, 13)], lineup: lineup)
        #expect(f.artists(onDay: 1).map(\.id) == ["a", "c"])
        #expect(f.artists(onDay: nil).count == 3)
    }

    @Test func laPortadaMuestraMaximoDiezPorPeso() {
        let f = Fixtures.festival(id: "x-2026", dates: [Fixtures.day(2026, 3, 13)],
                                  lineup: Fixtures.lineup(count: 30))
        let headline = f.headlineArtists()
        #expect(headline.count == 10)
        // Los de mayor peso primero: las 2 cabezas de cartel encabezan.
        #expect(headline[0].tier == .headliner)
        #expect(headline[1].tier == .headliner)
    }

    @Test func unCartelChicoSeMuestraEntero() {
        let f = Fixtures.festival(id: "x-2026", dates: [Fixtures.day(2026, 3, 13)],
                                  lineup: Fixtures.lineup(count: 7))
        #expect(f.headlineArtists().count == 7)
    }

    @Test func modoDescubrimientoExcluyeLosNombresGrandes() {
        let f = Fixtures.festival(id: "x-2026", dates: [Fixtures.day(2026, 3, 13)],
                                  lineup: Fixtures.lineup(count: 12))
        let discovery = f.discoveryArtists()
        // La fixture arma 2 headliners + 3 estelares: quedan fuera.
        #expect(discovery.count == 7)
        #expect(discovery.allSatisfy { $0.tier == .mid || $0.tier == .emerging })
    }

    @Test func modoDescubrimientoRespetaElDiaYLosSinConfirmar() {
        let lineup = [
            Fixtures.artist("grande", tier: .headliner, day: 1),
            Fixtures.artist("chico-d1", tier: .mid, day: 1),
            Fixtures.artist("chico-d2", tier: .emerging, day: 2),
            Fixtures.artist("chico-sin-dia", tier: .emerging, day: nil),
        ]
        let f = Fixtures.festival(id: "x-2026", dates: [Fixtures.day(2026, 3, 13)],
                                  lineup: lineup)
        #expect(f.discoveryArtists(onDay: 1).map(\.id) == ["chico-d1", "chico-sin-dia"])
    }

    @Test func cartelSoloDeGrandesNoTieneDescubrimiento() {
        let lineup = [Fixtures.artist("a", tier: .headliner),
                      Fixtures.artist("b", tier: .main)]
        let f = Fixtures.festival(id: "x-2026", dates: [Fixtures.day(2026, 3, 13)],
                                  lineup: lineup)
        #expect(f.discoveryArtists().isEmpty)
    }

    @Test func hasDayBreakdownSoloConDiasAsignados() {
        let sinDias = Fixtures.festival(id: "x-2026", dates: [Fixtures.day(2026, 3, 13)],
                                        lineup: [Fixtures.artist("a"), Fixtures.artist("b")])
        #expect(!sinDias.hasDayBreakdown)
        let conDias = Fixtures.festival(id: "y-2026", dates: [Fixtures.day(2026, 3, 13)],
                                        lineup: [Fixtures.artist("a", day: 1)])
        #expect(conDias.hasDayBreakdown)
    }

    @Test func estadoTemporalPasadoEnCursoProximo() {
        let pasado = Fixtures.festival(id: "p-2023", dates: [Fixtures.day(2023, 11, 11)])
        #expect(pasado.isPast && !pasado.isOngoing && !pasado.isUpcoming)
        let futuro = Fixtures.festival(id: "f-2099", dates: [Fixtures.day(2099, 3, 13)])
        #expect(futuro.isUpcoming && !futuro.isPast)
    }

    @Test func archivadoSoloTrasUnaSemanaDelCierre() {
        // Terminado hace años: archivado.
        let antiguo = Fixtures.festival(id: "a-2023", dates: [Fixtures.day(2023, 11, 11)])
        #expect(antiguo.isArchived)
        // Terminado anteayer: pasado pero todavía vigente en el carrusel.
        let cal = Fixtures.santiago
        let anteayer = cal.startOfDay(for: cal.date(byAdding: .day, value: -2, to: .now)!)
        let reciente = Fixtures.festival(id: "r-x", dates: [anteayer])
        #expect(reciente.isPast && !reciente.isArchived)
        // Futuro: nunca archivado.
        let futuro = Fixtures.festival(id: "f-2099", dates: [Fixtures.day(2099, 3, 13)])
        #expect(!futuro.isArchived)
    }

    @Test func rangoDeFechasMismoMesConAñoDistinto() {
        let f = Fixtures.festival(id: "x-2025",
                                  dates: [Fixtures.day(2025, 11, 7), Fixtures.day(2025, 11, 8)])
        // "7–8 nov '25" (la abreviatura del mes depende del locale data; se
        // verifica la estructura estable: días con guión en y sufijo de año).
        #expect(f.dateRangeLabel.hasPrefix("7–8 "))
        #expect(f.dateRangeLabel.hasSuffix("'25"))
    }

    @Test func rangoDeFechasCruzaMeses() {
        let f = Fixtures.festival(id: "x-2099",
                                  dates: [Fixtures.day(2099, 11, 30), Fixtures.day(2099, 12, 1)])
        #expect(f.dateRangeLabel.contains(" – "))
    }

    @Test func elFeedSeOrdenaCronologicamente() {
        let feed = FestivalFeed(version: 1, updatedAt: .now, festivals: [
            Fixtures.festival(id: "b-2026", dates: [Fixtures.day(2026, 11, 6)]),
            Fixtures.festival(id: "a-2023", dates: [Fixtures.day(2023, 3, 17)]),
        ]).chronological
        #expect(feed.festivals.map(\.id) == ["a-2023", "b-2026"])
    }
}

// MARK: - Color(hex:)

@Suite struct ColorHexTests {

    @Test func hexInvalidoCaeAGris() {
        // El fallback es visible a propósito (no negro silencioso).
        #expect(Color(hex: "no-es-hex") == .gray)
        #expect(Color(hex: "#12345") == .gray)   // largo inválido
    }

    @Test func hexValidoNoEsGris() {
        #expect(Color(hex: "#E4002B") != .gray)
        #expect(Color(hex: "E4002B") != .gray)   // sin '#' también vale
        #expect(Color(hex: "#F00") != .gray)     // forma corta RGB
    }
}
