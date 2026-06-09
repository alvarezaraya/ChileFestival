import SwiftUI
import Combine

// MARK: - Cuerpo físico (un círculo de artista)

struct PhysicsBody: Identifiable, Sendable {
    let artist: LineupArtist
    let radius: CGFloat
    var position: CGPoint
    var velocity: CGVector = .zero
    /// Posición radial deseada (0 = centro … 1 = borde) según el lugar en el
    /// cartel: los cabeza de cartel quedan al centro y los emergentes orbitan
    /// hacia afuera (orden centrípeto).
    var orderT: CGFloat = 0
    var id: String { artist.id }
}

// MARK: - Simulación

/// Motor de física muy ligero: gravedad centrípeta + colisiones + paredes.
///
/// El cómputo (step, configure, drag) se ejecuta en una **cola serial dedicada**
/// fuera del main thread. Sólo la publicación del snapshot a `@Published bodies`
/// vuelve al main para que SwiftUI re-renderice. Con dos festivales y 50 cuerpos
/// cada uno, mantener el step en main saturaba el run loop y bloqueaba gestos.
final class ClusterPhysics: ObservableObject {

    @Published private(set) var bodies: [PhysicsBody] = []

    /// Cola serial dedicada: aísla la simulación del main thread.
    private let queue = DispatchQueue(label: "ClusterPhysics", qos: .userInteractive)

    // Estado interno: SÓLO se accede dentro de `queue`.
    private var simBodies: [PhysicsBody] = []
    private var simBounds: CGSize = .zero
    private var simDraggingID: String?
    private var simConfiguredIDs: [String] = []
    private var simRestFrames = 0
    private var simAtRest = false

    /// Evita acumular trabajo si el cómputo va más lento que el reloj. Sólo se
    /// lee/escribe desde main thread.
    private var stepInFlight = false

    // Ajuste (puntos · segundos).
    private let centripetal: CGFloat = 9.0     // rigidez del resorte radial al anillo objetivo
    private let wallRestitution: CGFloat = 0.32
    private let bodyRestitution: CGFloat = 0.18
    private let linearDamping: CGFloat = 0.90

    // MARK: Configuración

    /// Crea los cuerpos para `artists`. Si el lineup no cambió, solo reescala las
    /// posiciones al nuevo `size` (transición silueta ⇄ pantalla completa).
    func configure(artists: [LineupArtist], size: CGSize,
                   minRadius: CGFloat = 26, maxRadius: CGFloat = 62) {
        guard size.width > 1, size.height > 1 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.configureLocked(artists: artists, size: size,
                                 minRadius: minRadius, maxRadius: maxRadius)
            let snapshot = self.simBodies
            DispatchQueue.main.async { self.bodies = snapshot }
        }
    }

    private func configureLocked(artists: [LineupArtist], size: CGSize,
                                 minRadius: CGFloat, maxRadius: CGFloat) {
        let ids = artists.map(\.id)
        if ids == simConfiguredIDs, !simBodies.isEmpty {
            rescaleLocked(to: size)
            return
        }
        simConfiguredIDs = ids
        simBounds = size
        wakeLocked()

        // Radio por peso (área ∝ peso → sqrt para una percepción visual correcta).
        let radii = artists.map { a in
            minRadius + (maxRadius - minRadius) * CGFloat(sqrt(a.billingWeight))
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let count = artists.count
        // Reparto inicial en espiral alrededor del centro: flotan y se ordenan
        // de forma centrípeta (cabezas de cartel al centro, emergentes afuera).
        simBodies = artists.enumerated().map { i, a in
            let r = radii[i]
            let t = count <= 1 ? 0 : CGFloat(i) / CGFloat(count - 1)
            let angle = CGFloat(i) * 2.399963        // ángulo áureo → reparto uniforme
            let seed = t * min(size.width, size.height) * 0.35
            let p = CGPoint(x: center.x + cos(angle) * seed,
                            y: center.y + sin(angle) * seed)
            return PhysicsBody(artist: a, radius: r,
                               position: clampInsideLocked(p, radius: r), orderT: t)
        }
    }

    private func rescaleLocked(to size: CGSize) {
        guard simBounds.width > 1, simBounds.height > 1 else { simBounds = size; return }
        let sx = size.width / simBounds.width
        let sy = size.height / simBounds.height
        guard abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 else { return }
        for i in simBodies.indices {
            simBodies[i].position.x *= sx
            simBodies[i].position.y *= sy
        }
        simBounds = size
        // Pequeña perturbación para que reacomoden al nuevo marco.
        for i in simBodies.indices where simBodies[i].id != simDraggingID {
            simBodies[i].velocity.dx += .random(in: -20...20)
            simBodies[i].velocity.dy += .random(in: -20...20)
        }
        wakeLocked()
    }

    /// Reactiva la simulación: vuelve a estepear/publicar hasta que se asiente.
    private func wakeLocked() {
        simAtRest = false
        simRestFrames = 0
    }

    // MARK: Step

    /// Despacha un paso de simulación a la cola serial. Si ya hay un step en
    /// vuelo, descarta éste (preferimos perder un frame de física antes que
    /// acumular trabajo cuando la cola está ocupada con drags/configure).
    func step(_ dt: CGFloat) {
        guard !stepInFlight else { return }
        stepInFlight = true
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { self?.stepInFlight = false }
                return
            }
            self.stepLocked(dt)
            // Si la simulación está en reposo y no hay drag, no tocamos `bodies`
            // para no invalidar la View 30 veces/segundo en vano.
            let publish = !(self.simAtRest && self.simDraggingID == nil)
            let snapshot = publish ? self.simBodies : nil
            DispatchQueue.main.async {
                if let snapshot { self.bodies = snapshot }
                self.stepInFlight = false
            }
        }
    }

    private func stepLocked(_ dt: CGFloat) {
        guard simBounds.width > 1, !simBodies.isEmpty else { return }
        if simAtRest && simDraggingID == nil { return }
        let h = min(max(dt, 0), 1.0 / 30.0)   // clamp para saltos de frame
        guard h > 0 else { return }

        let center = CGPoint(x: simBounds.width / 2, y: simBounds.height / 2)
        let maxReach = max(20, min(simBounds.width, simBounds.height) / 2)

        for i in simBodies.indices where simBodies[i].id != simDraggingID {
            // Resorte radial hacia el anillo objetivo (orden centrípeto): la
            // distancia al centro tiende a `target`, mientras el componente
            // tangencial queda libre para que floten y se repartan.
            let dx = simBodies[i].position.x - center.x
            let dy = simBodies[i].position.y - center.y
            var d = sqrt(dx * dx + dy * dy)
            if d < 0.01 { d = 0.01 }
            let ux = dx / d, uy = dy / d
            let target = sqrt(simBodies[i].orderT) * max(0, maxReach - simBodies[i].radius - 6)
            let err = d - target                       // >0 demasiado afuera → atraer
            simBodies[i].velocity.dx += -err * ux * centripetal * h
            simBodies[i].velocity.dy += -err * uy * centripetal * h

            simBodies[i].velocity.dx *= linearDamping
            simBodies[i].velocity.dy *= linearDamping
            simBodies[i].position.x += simBodies[i].velocity.dx * h
            simBodies[i].position.y += simBodies[i].velocity.dy * h
        }

        // Varias iteraciones de relajación estabilizan el reparto.
        for _ in 0..<4 { resolveCollisionsLocked() }
        resolveWallsLocked()

        // Detección de reposo: si todo se mueve por debajo de un umbral durante
        // varios frames, congelamos velocidades y dejamos de publicar.
        if simDraggingID == nil {
            var maxSpeed: CGFloat = 0
            for b in simBodies {
                maxSpeed = max(maxSpeed, abs(b.velocity.dx) + abs(b.velocity.dy))
            }
            if maxSpeed < 3 {
                simRestFrames += 1
                if simRestFrames > 24 {
                    for i in simBodies.indices { simBodies[i].velocity = .zero }
                    simAtRest = true
                }
            } else {
                simRestFrames = 0
            }
        } else {
            simRestFrames = 0
        }
    }

    private func resolveCollisionsLocked() {
        guard simBodies.count > 1 else { return }
        for i in 0..<simBodies.count {
            for j in (i + 1)..<simBodies.count {
                let dx = simBodies[j].position.x - simBodies[i].position.x
                let dy = simBodies[j].position.y - simBodies[i].position.y
                var dist = sqrt(dx * dx + dy * dy)
                let minDist = simBodies[i].radius + simBodies[j].radius
                guard dist < minDist else { continue }
                if dist == 0 { dist = 0.01 }
                let nx = dx / dist, ny = dy / dist
                let overlap = minDist - dist

                let aMoves = simBodies[i].id != simDraggingID
                let bMoves = simBodies[j].id != simDraggingID

                // Corrección posicional.
                if aMoves && bMoves {
                    simBodies[i].position.x -= nx * overlap / 2
                    simBodies[i].position.y -= ny * overlap / 2
                    simBodies[j].position.x += nx * overlap / 2
                    simBodies[j].position.y += ny * overlap / 2
                } else if aMoves {
                    simBodies[i].position.x -= nx * overlap
                    simBodies[i].position.y -= ny * overlap
                } else if bMoves {
                    simBodies[j].position.x += nx * overlap
                    simBodies[j].position.y += ny * overlap
                }

                // Respuesta de velocidad a lo largo de la normal.
                let rvx = simBodies[j].velocity.dx - simBodies[i].velocity.dx
                let rvy = simBodies[j].velocity.dy - simBodies[i].velocity.dy
                let vn = rvx * nx + rvy * ny
                if vn < 0 {
                    let impulse = -(1 + bodyRestitution) * vn / 2
                    if aMoves {
                        simBodies[i].velocity.dx -= impulse * nx
                        simBodies[i].velocity.dy -= impulse * ny
                    }
                    if bMoves {
                        simBodies[j].velocity.dx += impulse * nx
                        simBodies[j].velocity.dy += impulse * ny
                    }
                }
            }
        }
    }

    private func resolveWallsLocked() {
        for i in simBodies.indices {
            let r = simBodies[i].radius
            if simBodies[i].position.x < r {
                simBodies[i].position.x = r
                simBodies[i].velocity.dx = abs(simBodies[i].velocity.dx) * wallRestitution
            } else if simBodies[i].position.x > simBounds.width - r {
                simBodies[i].position.x = simBounds.width - r
                simBodies[i].velocity.dx = -abs(simBodies[i].velocity.dx) * wallRestitution
            }
            if simBodies[i].position.y < r {
                simBodies[i].position.y = r
                simBodies[i].velocity.dy = abs(simBodies[i].velocity.dy) * wallRestitution
            } else if simBodies[i].position.y > simBounds.height - r {
                simBodies[i].position.y = simBounds.height - r
                simBodies[i].velocity.dy = -abs(simBodies[i].velocity.dy) * wallRestitution
            }
        }
    }

    // MARK: Arrastre

    func beginDrag(_ id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.simDraggingID = id
            self.wakeLocked()
        }
    }

    func drag(_ id: String, to point: CGPoint) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let i = self.simBodies.firstIndex(where: { $0.id == id }) else { return }
            self.simBodies[i].position = self.clampInsideLocked(point,
                                                                radius: self.simBodies[i].radius)
            self.simBodies[i].velocity = .zero
        }
    }

    /// Suelta el círculo con la velocidad del gesto (puntos/segundo).
    func endDrag(_ id: String, velocity: CGSize) {
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.simDraggingID = nil }
            guard let i = self.simBodies.firstIndex(where: { $0.id == id }) else { return }
            self.simBodies[i].velocity = CGVector(dx: velocity.width, dy: velocity.height)
        }
    }

    private func clampInsideLocked(_ p: CGPoint, radius r: CGFloat) -> CGPoint {
        CGPoint(x: min(max(p.x, r), max(r, simBounds.width - r)),
                y: min(max(p.y, r), max(r, simBounds.height - r)))
    }
}

// MARK: - Almacén de simulaciones (una por festival, compartida)

/// Vende y conserva una `ClusterPhysics` por id de festival para que la silueta y
/// la vista expandida operen sobre el mismo estado físico.
@MainActor
final class PhysicsStore: ObservableObject {
    private var models: [String: ClusterPhysics] = [:]

    func model(for festivalID: String) -> ClusterPhysics {
        if let m = models[festivalID] { return m }
        let m = ClusterPhysics()
        models[festivalID] = m
        return m
    }
}
