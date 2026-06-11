import SwiftUI
import Combine

// MARK: - Cuerpo físico (un círculo de artista)

struct PhysicsBody: Identifiable, Sendable {
    let artist: LineupArtist
    var radius: CGFloat
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
/// El cómputo (step, configure) se ejecuta en una **cola serial dedicada**
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
    private var simConfiguredIDs: [String] = []
    private var simRestFrames = 0
    private var simAtRest = false
    /// Radio del disco que empaca justo todos los círculos (ver `clusterPacking`).
    /// Tope del alcance del cúmulo: con carteles chicos en marcos grandes los
    /// mantiene agrupados al centro en vez de repartidos por todo el marco.
    private var simPackReach: CGFloat = .infinity

    /// Evita acumular trabajo si el cómputo va más lento que el reloj. Sólo se
    /// lee/escribe desde main thread.
    private var stepInFlight = false

    // Ajuste (puntos · segundos).
    private let centripetal: CGFloat = 9.0     // rigidez del resorte radial al anillo objetivo
    private let wallRestitution: CGFloat = 0.32
    private let bodyRestitution: CGFloat = 0.18
    private let linearDamping: CGFloat = 0.90
    /// Densidad de empaque del cúmulo (fracción del disco ocupada por círculos).
    /// Más alto = cúmulo más apretado. Determina `simPackReach`: con 0.68 los
    /// círculos de un cartel chico quedan rozándose en torno al centro.
    private let clusterPacking: CGFloat = 0.68

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
            rescaleLocked(to: size, artists: artists,
                          minRadius: minRadius, maxRadius: maxRadius)
            return
        }

        // Reconfiguración **incremental**. La portada simula solo los destacados
        // (para que llenen la silueta sea cual sea el tamaño del cartel) y la vista
        // expandida simula el cartel completo. En la transición, los cuerpos que
        // persisten (mismo id) CONSERVAN su posición —solo se reescala al nuevo
        // marco— mientras los nuevos (los tiers que se revelan al expandir) nacen
        // en la periferia y los que desaparecen (al colapsar) se descartan. Así los
        // destacados no saltan entre portada y vista expandida.
        let previous = Dictionary(simBodies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hadBounds = simBounds.width > 1 && simBounds.height > 1
        let sx = hadBounds ? size.width  / simBounds.width  : 1
        let sy = hadBounds ? size.height / simBounds.height : 1

        simConfiguredIDs = ids
        simBounds = size
        wakeLocked()

        let radii = packedRadiiLocked(for: artists, size: size,
                                      minRadius: minRadius, maxRadius: maxRadius)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let count = artists.count
        // `orderT` (radio objetivo) es un gradiente continuo por índice sobre el
        // cartel ya ordenado por peso: cabezas de cartel al centro y el resto hacia
        // afuera, sin huecos entre categorías.
        simBodies = artists.enumerated().map { i, a in
            let r = radii[i]
            let t = count <= 1 ? 0 : CGFloat(i) / CGFloat(count - 1)
            if let old = previous[a.id] {
                // Persiste: conserva posición (reescalada al nuevo marco) y velocidad.
                let p = clampInsideLocked(CGPoint(x: old.position.x * sx,
                                                  y: old.position.y * sy), radius: r)
                return PhysicsBody(artist: a, radius: r, position: p,
                                   velocity: old.velocity, orderT: t)
            } else {
                // Nuevo: nace en espiral (ángulo áureo) hacia su anillo objetivo.
                let angle = CGFloat(i) * 2.399963
                let seed = t * min(size.width, size.height) * 0.35
                let p = CGPoint(x: center.x + cos(angle) * seed,
                                y: center.y + sin(angle) * seed)
                return PhysicsBody(artist: a, radius: r,
                                   position: clampInsideLocked(p, radius: r), orderT: t)
            }
        }
    }

    /// Radios por categoría escalados al área del marco. Tres tamaños discretos
    /// (cabezas de cartel > estelares > resto) interpolando entre min y maxRadius
    /// según el factor del tier; luego una escala proporcional al área disponible:
    /// si la suma de las áreas de los círculos supera una fracción del marco (no
    /// caben sin solaparse), se encogen todos por igual hasta que quepan. Si sobra
    /// sitio, pueden crecer (hasta un tope) para llenar la silueta. `packing` < 1
    /// deja aire entre ellos (los círculos no teselan el plano perfectamente).
    ///
    /// Actualiza también `simPackReach` —el radio del disco que contiene justo
    /// todos los círculos: Σπr² = clusterPacking · πR² → R = √(Σr²/packing)—
    /// porque depende de los radios resultantes. En carteles grandes supera al
    /// alcance geométrico del marco y no actúa; en los chicos compacta el cúmulo
    /// para que los círculos siempre queden agrupados.
    private func packedRadiiLocked(for artists: [LineupArtist], size: CGSize,
                                   minRadius: CGFloat, maxRadius: CGFloat) -> [CGFloat] {
        var radii = artists.map { a in
            minRadius + (maxRadius - minRadius) * a.circleSizeFactor
        }
        if !radii.isEmpty {
            let packing: CGFloat = 0.42
            let frameArea = size.width * size.height
            let circlesArea = radii.reduce(0) { $0 + .pi * $1 * $1 }
            if circlesArea > 0 {
                let fit = sqrt(packing * frameArea / circlesArea)
                let scale = min(fit, 1.6)   // encoge sin tope; crece hasta 1.6×
                radii = radii.map { $0 * scale }
            }
        }
        let sumR2 = radii.reduce(0) { $0 + $1 * $1 }
        simPackReach = sumR2 > 0 ? sqrt(sumR2 / clusterPacking) : .infinity
        return radii
    }

    private func rescaleLocked(to size: CGSize, artists: [LineupArtist],
                               minRadius: CGFloat, maxRadius: CGFloat) {
        guard simBounds.width > 1, simBounds.height > 1 else { simBounds = size; return }
        let sx = size.width / simBounds.width
        let sy = size.height / simBounds.height
        guard abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 else { return }
        // Los radios dependen del área del marco (ver packedRadiiLocked): hay que
        // recomputarlos para el nuevo tamaño, no solo reescalar posiciones. Sin
        // esto, un cartel que simula los mismos ids en la silueta y a pantalla
        // completa (festivales o días de ≤10 artistas) conserva al expandir los
        // radios chicos de la portada, y al colapsar los grandes del overlay.
        let radii = packedRadiiLocked(for: artists, size: size,
                                      minRadius: minRadius, maxRadius: maxRadius)
        for i in simBodies.indices {
            simBodies[i].position.x *= sx
            simBodies[i].position.y *= sy
            simBodies[i].radius = radii[i]
        }
        simBounds = size
        // Sin perturbación aleatoria: el reescalado es proporcional desde el
        // origen, así el centro (cabezas de cartel) se mantiene fijo y la
        // periferia se abre/cierra al hacer zoom entre la portada y la vista
        // expandida. Mantener las posiciones es justamente lo que da continuidad
        // a la transición; solo despertamos la simulación para que el resorte
        // reasiente cualquier solapamiento leve por cambio de proporción.
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
    /// acumular trabajo cuando la cola está ocupada con configure).
    func step(_ dt: CGFloat) {
        guard !stepInFlight else { return }
        stepInFlight = true
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { self?.stepInFlight = false }
                return
            }
            self.stepLocked(dt)
            // Si la simulación está en reposo, no tocamos `bodies` para no
            // invalidar la View 30 veces/segundo en vano.
            let snapshot = self.simAtRest ? nil : self.simBodies
            DispatchQueue.main.async {
                if let snapshot { self.bodies = snapshot }
                self.stepInFlight = false
            }
        }
    }

    private func stepLocked(_ dt: CGFloat) {
        guard simBounds.width > 1, !simBodies.isEmpty else { return }
        if simAtRest { return }
        let h = min(max(dt, 0), 1.0 / 30.0)   // clamp para saltos de frame
        guard h > 0 else { return }

        let center = CGPoint(x: simBounds.width / 2, y: simBounds.height / 2)
        // Alcance del cúmulo: el menor entre el geométrico (no salirse del marco)
        // y el de empaque (no dispersarse más de lo que ocupa el contenido).
        let maxReach = max(20, min(min(simBounds.width, simBounds.height) / 2,
                                   simPackReach))

        for i in simBodies.indices {
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

        // Más iteraciones = cero solapamiento garantizado en cada frame.
        for _ in 0..<10 { resolveCollisionsLocked() }
        resolveWallsLocked()

        // Detección de reposo: si todo se mueve por debajo de un umbral durante
        // varios frames, congelamos velocidades y dejamos de publicar.
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

                // Corrección posicional.
                simBodies[i].position.x -= nx * overlap / 2
                simBodies[i].position.y -= ny * overlap / 2
                simBodies[j].position.x += nx * overlap / 2
                simBodies[j].position.y += ny * overlap / 2

                // Respuesta de velocidad a lo largo de la normal.
                let rvx = simBodies[j].velocity.dx - simBodies[i].velocity.dx
                let rvy = simBodies[j].velocity.dy - simBodies[i].velocity.dy
                let vn = rvx * nx + rvy * ny
                if vn < 0 {
                    let impulse = -(1 + bodyRestitution) * vn / 2
                    simBodies[i].velocity.dx -= impulse * nx
                    simBodies[i].velocity.dy -= impulse * ny
                    simBodies[j].velocity.dx += impulse * nx
                    simBodies[j].velocity.dy += impulse * ny
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
