import Foundation
import UserNotifications

// MARK: - FestivalReminders
//
// Recordatorios locales para los festivales seguidos: una notificación una
// semana antes y otra la mañana del día de inicio. Todo con
// UNUserNotificationCenter — sin servidor, coherente con la app 100 % local.
//
// La fuente de verdad es (feed del bundle × series seguidas): `sync` se llama
// en cada arranque y cada vez que cambian los follows, borra lo agendado por
// la app y lo vuelve a agendar. Así los recordatorios sobreviven a cambios de
// datos entre versiones sin guardar estado propio.

enum FestivalReminders {

    /// Prefijo común de nuestros identifiers, para poder borrar solo lo
    /// nuestro sin tocar otras notificaciones pendientes.
    private static let idPrefix = "festival-reminder."

    /// Reagenda los recordatorios según los follows actuales. La autorización
    /// se pide aquí la primera vez (justo después de elegir festivales, cuando
    /// el permiso tiene contexto); si el usuario la negó, no se insiste.
    static func sync(feed: FestivalFeed, followedKeys: [String]) async {
        let center = UNUserNotificationCenter.current()

        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        if !ours.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }

        guard !followedKeys.isEmpty else { return }

        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
        case .denied:
            return
        default:
            break
        }

        for series in feed.series where followedKeys.contains(series.key) {
            guard let next = series.nextEdition else { continue }
            for request in requests(for: next) {
                try? await center.add(request)
            }
        }
    }

    // MARK: Armado de recordatorios

    private static func requests(for festival: Festival) -> [UNNotificationRequest] {
        var requests: [UNNotificationRequest] = []
        let now = Date()

        // Una semana antes, a mediodía: fechas + recinto para planificar.
        if let weekBefore = calendar.date(byAdding: .day, value: -7, to: festival.startDate),
           let fireDate = fireDate(at: 12, of: weekBefore), fireDate > now {
            requests.append(request(
                id: festival.id + ".semana",
                title: "\(festival.name) empieza en una semana",
                body: "\(festival.dateRangeLabel) · \(festival.venue), \(festival.city). El cartel completo te espera en la app.",
                fireDate: fireDate))
        }

        // La mañana del primer día.
        if let fireDate = fireDate(at: 9, of: festival.startDate), fireDate > now {
            requests.append(request(
                id: festival.id + ".hoy",
                title: "¡Hoy empieza \(festival.name)!",
                body: "\(festival.venue), \(festival.city). Dale play al mix del cartel mientras te preparas.",
                fireDate: fireDate))
        }

        return requests
    }

    private static func request(id: String, title: String, body: String,
                                fireDate: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                                 from: fireDate)
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        return UNNotificationRequest(identifier: idPrefix + id,
                                     content: content, trigger: trigger)
    }

    /// Mismo día que `date` (que viene a medianoche de Santiago, como todas
    /// las fechas del feed) pero a la hora indicada.
    private static func fireDate(at hour: Int, of date: Date) -> Date? {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago") ?? .current
        return c
    }()
}
