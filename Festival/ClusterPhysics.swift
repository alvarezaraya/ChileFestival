import SwiftUI
import Combine

// MARK: - Cuerpo físico (un círculo de artista)

struct PhysicsBody: Identifiable {
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

/// Motor de física muy ligero: gravedad + colisiones + paredes. Se comparte por
/// referencia entre la silueta colapsada y la vista a pantalla completa para que
/// los círculos mantengan su estado al expandir (solo se reescalan al nuevo marco).
@MainActor
final class ClusterPhysics: ObservableObject {

    @Published private(set) var bodies: [PhysicsBody] = []
    private(set) var bounds: CGSize = .zero

    private var draggingID: String?
    private var configuredIDs: [String] = []

    // Ajuste (puntos · segundos).
    private let centripetal: CGFloat = 9.0     // rigidez del resorte radial al anillo objetivo
    private let wallRestitution: CGFloat = 0.32
    private let bodyRestitution: CGFloat = 0.18
    private let linearDamping: CGFloat = 0.90

    var isDragging: Bool { draggingID != nil }

    // MARK: Configuración

    /// Crea los cuerpos para `artists`. Si el lineup no cambió, solo reescala las
    /// posiciones al nuevo `size` (transición silueta ⇄ pantalla completa).
    func configure(artists: [LineupArtist], size: CGSize,
                   minRadius: CGFloat = 26, maxRadius: CGFloat = 62) {
        guard size.width > 1, size.height > 1 else { return }

        let ids = artists.map(\.id)
        if ids == configuredIDs, !bodies.isEmpty {
            rescale(to: size)
            return
        }
        configuredIDs = ids
        bounds = size

        // Radio por peso (área ∝ peso → sqrt para una percepción visual correcta).
        let radii = artists.map { a in
            minRadius + (maxRadius - minRadius) * CGFloat(sqrt(a.billingWeight))
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let count = artists.count
        // Reparto inicial en espiral alrededor del centro: flotan y se ordenan
        // de forma centrípeta (cabezas de cartel al centro, emergentes afuera).
        bodies = artists.enumerated().map { i, a in
            let r = radii[i]
            let t = count <= 1 ? 0 : CGFloat(i) / CGFloat(count - 1)
            let angle = CGFloat(i) * 2.399963        // ángulo áureo → reparto uniforme
            let seed = t * min(size.width, size.height) * 0.35
            let p = CGPoint(x: center.x + cos(angle) * seed,
                            y: center.y + sin(angle) * seed)
            return PhysicsBody(artist: a, radius: r,
                               position: clampInside(p, radius: r), orderT: t)
        }
    }

    private func rescale(to size: CGSize) {
        guard bounds.width > 1, bounds.height > 1 else { bounds = size; return }
        let sx = size.width / bounds.width
        let sy = size.height / bounds.height
        guard abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 else { return }
        for i in bodies.indices {
            bodies[i].position.x *= sx
            bodies[i].position.y *= sy
        }
        bounds = size
        // Pequeña perturbación para que reacomoden al nuevo marco.
        for i in bodies.indices where bodies[i].id != draggingID {
            bodies[i].velocity.dx += .random(in: -20...20)
            bodies[i].velocity.dy += .random(in: -20...20)
        }
    }

    // MARK: Paso de integración

    func step(_ dt: CGFloat) {
        guard bounds.width > 1, !bodies.isEmpty else { return }
        let h = min(max(dt, 0), 1.0 / 30.0)   // clamp para saltos de frame
        guard h > 0 else { return }

        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let maxReach = max(20, min(bounds.width, bounds.height) / 2)

        for i in bodies.indices where bodies[i].id != draggingID {
            // Resorte radial hacia el anillo objetivo (orden centrípeto): la
            // distancia al centro tiende a `target`, mientras el componente
            // tangencial queda libre para que floten y se repartan.
            let dx = bodies[i].position.x - center.x
            let dy = bodies[i].position.y - center.y
            var d = sqrt(dx * dx + dy * dy)
            if d < 0.01 { d = 0.01 }
            let ux = dx / d, uy = dy / d
            let target = sqrt(bodies[i].orderT) * max(0, maxReach - bodies[i].radius - 6)
            let err = d - target                       // >0 demasiado afuera → atraer
            bodies[i].velocity.dx += -err * ux * centripetal * h
            bodies[i].velocity.dy += -err * uy * centripetal * h

            bodies[i].velocity.dx *= linearDamping
            bodies[i].velocity.dy *= linearDamping
            bodies[i].position.x += bodies[i].velocity.dx * h
            bodies[i].position.y += bodies[i].velocity.dy * h
        }

        // Varias iteraciones de relajación estabilizan el reparto.
        for _ in 0..<4 { resolveCollisions() }
        resolveWalls()
    }

    private func resolveCollisions() {
        guard bodies.count > 1 else { return }
        for i in 0..<bodies.count {
            for j in (i + 1)..<bodies.count {
                let dx = bodies[j].position.x - bodies[i].position.x
                let dy = bodies[j].position.y - bodies[i].position.y
                var dist = sqrt(dx * dx + dy * dy)
                let minDist = bodies[i].radius + bodies[j].radius
                guard dist < minDist else { continue }
                if dist == 0 { dist = 0.01 }
                let nx = dx / dist, ny = dy / dist
                let overlap = minDist - dist

                let aMoves = bodies[i].id != draggingID
                let bMoves = bodies[j].id != draggingID

                // Corrección posicional.
                if aMoves && bMoves {
                    bodies[i].position.x -= nx * overlap / 2
                    bodies[i].position.y -= ny * overlap / 2
                    bodies[j].position.x += nx * overlap / 2
                    bodies[j].position.y += ny * overlap / 2
                } else if aMoves {
                    bodies[i].position.x -= nx * overlap
                    bodies[i].position.y -= ny * overlap
                } else if bMoves {
                    bodies[j].position.x += nx * overlap
                    bodies[j].position.y += ny * overlap
                }

                // Respuesta de velocidad a lo largo de la normal.
                let rvx = bodies[j].velocity.dx - bodies[i].velocity.dx
                let rvy = bodies[j].velocity.dy - bodies[i].velocity.dy
                let vn = rvx * nx + rvy * ny
                if vn < 0 {
                    let impulse = -(1 + bodyRestitution) * vn / 2
                    if aMoves {
                        bodies[i].velocity.dx -= impulse * nx
                        bodies[i].velocity.dy -= impulse * ny
                    }
                    if bMoves {
                        bodies[j].velocity.dx += impulse * nx
                        bodies[j].velocity.dy += impulse * ny
                    }
                }
            }
        }
    }

    private func resolveWalls() {
        for i in bodies.indices {
            let r = bodies[i].radius
            if bodies[i].position.x < r {
                bodies[i].position.x = r
                bodies[i].velocity.dx = abs(bodies[i].velocity.dx) * wallRestitution
            } else if bodies[i].position.x > bounds.width - r {
                bodies[i].position.x = bounds.width - r
                bodies[i].velocity.dx = -abs(bodies[i].velocity.dx) * wallRestitution
            }
            if bodies[i].position.y < r {
                bodies[i].position.y = r
                bodies[i].velocity.dy = abs(bodies[i].velocity.dy) * wallRestitution
            } else if bodies[i].position.y > bounds.height - r {
                bodies[i].position.y = bounds.height - r
                bodies[i].velocity.dy = -abs(bodies[i].velocity.dy) * wallRestitution
            }
        }
    }

    // MARK: Arrastre

    func beginDrag(_ id: String) {
        draggingID = id
    }

    func drag(_ id: String, to point: CGPoint) {
        guard let i = bodies.firstIndex(where: { $0.id == id }) else { return }
        bodies[i].position = clampInside(point, radius: bodies[i].radius)
        bodies[i].velocity = .zero
    }

    /// Suelta el círculo con la velocidad del gesto (puntos/segundo).
    func endDrag(_ id: String, velocity: CGSize) {
        defer { draggingID = nil }
        guard let i = bodies.firstIndex(where: { $0.id == id }) else { return }
        bodies[i].velocity = CGVector(dx: velocity.width, dy: velocity.height)
    }

    private func clampInside(_ p: CGPoint, radius r: CGFloat) -> CGPoint {
        CGPoint(x: min(max(p.x, r), max(r, bounds.width - r)),
                y: min(max(p.y, r), max(r, bounds.height - r)))
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
