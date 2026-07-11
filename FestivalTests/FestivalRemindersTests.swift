import Foundation
import Testing
import UserNotifications
@testable import Festival

// MARK: - Recordatorios: qué se agenda y qué no
//
// Se testea el armado (`requests(for:)`), no el UNUserNotificationCenter.
// Las fixtures se construyen relativas a hoy para que los tests no caduquen.

@Suite struct FestivalRemindersTests {

    private func festival(startingIn days: Int, id: String = "test-2099") -> Festival {
        let cal = Fixtures.santiago
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: days, to: .now)!)
        return Fixtures.festival(id: id, dates: [start])
    }

    @Test func festivalLejanoAgendaSemanaYDia() {
        let requests = FestivalReminders.requests(for: festival(startingIn: 30))
        #expect(requests.count == 2)
        #expect(requests[0].identifier.hasSuffix(".semana"))
        #expect(requests[1].identifier.hasSuffix(".hoy"))

        // Horas correctas y ancladas a Santiago.
        let triggers = requests.compactMap { $0.trigger as? UNCalendarNotificationTrigger }
        #expect(triggers.count == 2)
        #expect(triggers[0].dateComponents.hour == 12)
        #expect(triggers[1].dateComponents.hour == 9)
        for t in triggers {
            #expect(t.dateComponents.timeZone?.identifier == "America/Santiago")
            #expect(!t.repeats)
        }
    }

    @Test func festivalEnMenosDeUnaSemanaSoloAgendaElDia() {
        let requests = FestivalReminders.requests(for: festival(startingIn: 3))
        #expect(requests.count == 1)
        #expect(requests[0].identifier.hasSuffix(".hoy"))
    }

    @Test func festivalPasadoNoAgendaNada() {
        #expect(FestivalReminders.requests(for: festival(startingIn: -10)).isEmpty)
    }

    @Test func losIdentifiersLlevanElPrefijoDeLaApp() {
        // El prefijo permite borrar solo lo nuestro al resincronizar.
        let requests = FestivalReminders.requests(for: festival(startingIn: 30))
        for r in requests {
            #expect(r.identifier.hasPrefix("festival-reminder."))
            #expect(r.identifier.contains("test-2099"))
        }
    }

    @Test func elContenidoNombraAlFestival() {
        let requests = FestivalReminders.requests(for: festival(startingIn: 30))
        for r in requests {
            #expect(r.content.title.contains("Fest"))
        }
    }
}
