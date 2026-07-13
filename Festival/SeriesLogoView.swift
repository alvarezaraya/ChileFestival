import SwiftUI

// MARK: - Logos vectoriales por serie
//
// Cada festival de la pantalla de selección muestra una versión vectorial de
// su logo oficial, dibujada a mano en SwiftUI (sin assets ni red: funciona
// offline y pesa cero). Los diseños son interpretaciones compactas del
// emblema de cada marca — la gaviota de Viña, la chupalla de Olmué, el
// planeta de En Órbita — pensadas para leerse a 46 pt. Las series sin diseño
// propio (festivales que se agreguen al feed en el futuro) caen a un
// monograma con las iniciales del nombre sobre su color de acento.

struct SeriesLogoView: View {
    let series: FestivalSeries
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle().fill(background)
            mark
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    // Fondo del disco: el color editorial del logo cuando lo tiene, si no el
    // acento de la serie (mismo criterio que usaba el ícono genérico).
    private var background: AnyShapeStyle {
        switch series.key {
        case "rec":                 return AnyShapeStyle(Color(hex: "#1A9E8F"))
        case "muda":                return AnyShapeStyle(Color(hex: "#189BA8"))
        case "bamba":               return AnyShapeStyle(Color(hex: "#7EC8F2"))
        case "fauna-primavera":     return AnyShapeStyle(Color(hex: "#1C1C1E"))
        case "en-orbita":           return AnyShapeStyle(Color(hex: "#101A33"))
        case "primavera-sound-santiago": return AnyShapeStyle(Color.black)
        case "creamfields-chile":   return AnyShapeStyle(Color.black)
        case "ruidosa-fest":        return AnyShapeStyle(Color(hex: "#1C1C1E"))
        case "vina-del-mar":        return AnyShapeStyle(Color(hex: "#0E3E8A").gradient)
        case "rockout-festival":    return AnyShapeStyle(Color.black)
        case "santiago-gets-louder": return AnyShapeStyle(Color(hex: "#141414"))
        case "la-cumbre-del-rock-chileno": return AnyShapeStyle(Color(hex: "#C81E1E"))
        case "frontera-festival":   return AnyShapeStyle(Color(hex: "#E8622D"))
        case "rockodromo":          return AnyShapeStyle(Color(hex: "#C81E2E"))
        case "maquinaria-festival": return AnyShapeStyle(Color(hex: "#5A0E0E").gradient)
        default:                    return AnyShapeStyle(series.accentColor.gradient)
        }
    }

    @ViewBuilder private var mark: some View {
        let s = size
        switch series.key {
        case "vina-del-mar":            GaviotaMark(size: s)
        case "rec":                     RECMark(size: s)
        case "en-orbita":               OrbitaMark(size: s)
        case "festival-del-huaso-de-olmue": ChupallaMark(size: s)
        case "creamfields-chile":       CreamMark(size: s)
        case "primavera-sound-santiago": ZigzagMark(size: s)
        case "womad-chile":             WomadMark(size: s)
        case "fauna-primavera":         FaunaMark(size: s)
        case "muda":                    MudaMark(size: s)
        case "bamba":                   BambaMark(size: s)
        case "ruidosa-fest":            RuidosaMark(size: s)
        case "lollapalooza-chile":      StackedWordMark(lines: ["LOLLA"], size: s)
        case "rockout-festival":        StackedWordMark(lines: ["ROCK", "OUT"], size: s, color: Color(hex: "#E03A2F"))
        case "rockodromo":              StackedWordMark(lines: ["ROCKÓ", "DROMO"], size: s)
        case "frontera-festival":       FronteraMark(size: s)
        case "la-cumbre-del-rock-chileno": CumbreMark(size: s)
        case "santiago-gets-louder":    SGLMark(size: s)
        case "maquinaria-festival":     GearMark(size: s)
        default:                        MonogramMark(name: series.name, size: s)
        }
    }
}

// MARK: Fallback — monograma de iniciales

private struct MonogramMark: View {
    let name: String
    let size: CGFloat

    /// Iniciales de las palabras significativas del nombre ("Festival de
    /// Viña del Mar" → "VM"), máximo dos letras.
    private var initials: String {
        let stop: Set<String> = ["festival", "fest", "de", "del", "la", "el", "los", "las", "en", "y"]
        let words = name.split(separator: " ").map(String.init)
            .filter { !stop.contains($0.lowercased()) }
        let letters = (words.isEmpty ? [name] : words).prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
    }
}

/// Wordmark apilado genérico (p. ej. "LOLLA", "ROCKÓ/DROMO").
private struct StackedWordMark: View {
    let lines: [String]
    let size: CGFloat
    var color: Color = .white

    var body: some View {
        VStack(spacing: -size * 0.02) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: size * (lines.count > 1 ? 0.24 : 0.30),
                                  weight: .black, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, size * 0.10)
    }
}

// MARK: Viña del Mar — la gaviota

private struct GaviotaMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, cg in
            let w = cg.width, h = cg.height
            var wings = Path()
            // Ala izquierda: curva que sube desde el costado al centro.
            wings.move(to: CGPoint(x: w * 0.10, y: h * 0.58))
            wings.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.42),
                               control: CGPoint(x: w * 0.28, y: h * 0.30))
            // Ala derecha: espejo.
            wings.addQuadCurve(to: CGPoint(x: w * 0.90, y: h * 0.58),
                               control: CGPoint(x: w * 0.72, y: h * 0.30))
            // Borde inferior de las alas, de vuelta al punto de partida.
            wings.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.56),
                               control: CGPoint(x: w * 0.72, y: h * 0.44))
            wings.addQuadCurve(to: CGPoint(x: w * 0.10, y: h * 0.58),
                               control: CGPoint(x: w * 0.28, y: h * 0.44))
            ctx.fill(wings, with: .color(.white))
            // Cuerpo/cola bajo las alas.
            var body = Path()
            body.move(to: CGPoint(x: w * 0.42, y: h * 0.52))
            body.addQuadCurve(to: CGPoint(x: w * 0.58, y: h * 0.52),
                              control: CGPoint(x: w * 0.50, y: h * 0.48))
            body.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.78),
                              control: CGPoint(x: w * 0.56, y: h * 0.68))
            body.addQuadCurve(to: CGPoint(x: w * 0.42, y: h * 0.52),
                              control: CGPoint(x: w * 0.44, y: h * 0.68))
            ctx.fill(body, with: .color(.white))
        }
        .frame(width: size, height: size)
    }
}

// MARK: REC — disco de gajos multicolores + sigla

private struct RECMark: View {
    let size: CGFloat
    private let palette: [Color] = [
        Color(hex: "#E94F35"), Color(hex: "#F5A623"), Color(hex: "#54B948"),
        Color(hex: "#1A9E8F"), Color(hex: "#D94F8E"), Color(hex: "#F2C94C"),
        Color(hex: "#2D9CDB"), Color(hex: "#EB5757"),
    ]

    var body: some View {
        ZStack {
            Canvas { ctx, cg in
                let c = CGPoint(x: cg.width / 2, y: cg.height / 2)
                let r = cg.width * 0.75
                let n = palette.count
                for i in 0..<n {
                    let a0 = Angle(degrees: Double(i) / Double(n) * 360 - 90)
                    let a1 = Angle(degrees: Double(i + 1) / Double(n) * 360 - 90)
                    var wedge = Path()
                    wedge.move(to: c)
                    wedge.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
                    wedge.closeSubpath()
                    ctx.fill(wedge, with: .color(palette[i]))
                }
            }
            Text("REC")
                .font(.system(size: size * 0.34, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1)
        }
        .frame(width: size, height: size)
    }
}

// MARK: En Órbita — planeta anillado y estrellas

private struct OrbitaMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // Estrellas de cuatro puntas, como en el afiche.
            SparkleShape()
                .fill(.white)
                .frame(width: size * 0.14, height: size * 0.14)
                .offset(x: -size * 0.28, y: -size * 0.22)
            SparkleShape()
                .fill(.white.opacity(0.85))
                .frame(width: size * 0.09, height: size * 0.09)
                .offset(x: size * 0.30, y: size * 0.24)
            // Planeta.
            Circle()
                .fill(.white)
                .frame(width: size * 0.42, height: size * 0.42)
            // Anillo.
            Ellipse()
                .strokeBorder(.white, lineWidth: size * 0.045)
                .frame(width: size * 0.78, height: size * 0.26)
                .rotationEffect(.degrees(-18))
        }
        .frame(width: size, height: size)
    }
}

/// Estrella de cuatro puntas (destello).
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX, cy = rect.midY
        let pinch = 0.18 // qué tan angosta es la cintura
        var p = Path()
        p.move(to: CGPoint(x: cx, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: cy),
                       control: CGPoint(x: cx + w * pinch, y: cy - h * pinch))
        p.addQuadCurve(to: CGPoint(x: cx, y: rect.maxY),
                       control: CGPoint(x: cx + w * pinch, y: cy + h * pinch))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: cy),
                       control: CGPoint(x: cx - w * pinch, y: cy + h * pinch))
        p.addQuadCurve(to: CGPoint(x: cx, y: rect.minY),
                       control: CGPoint(x: cx - w * pinch, y: cy - h * pinch))
        p.closeSubpath()
        return p
    }
}

// MARK: Olmué — la chupalla del huaso

private struct ChupallaMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, cg in
            let w = cg.width, h = cg.height
            let straw = Color(hex: "#E8C97A")
            // Ala ancha.
            let brim = Path(ellipseIn: CGRect(x: w * 0.10, y: h * 0.46,
                                              width: w * 0.80, height: h * 0.26))
            ctx.fill(brim, with: .color(straw))
            // Copa.
            var crown = Path()
            crown.move(to: CGPoint(x: w * 0.32, y: h * 0.56))
            crown.addLine(to: CGPoint(x: w * 0.34, y: h * 0.32))
            crown.addQuadCurve(to: CGPoint(x: w * 0.66, y: h * 0.32),
                               control: CGPoint(x: w * 0.50, y: h * 0.22))
            crown.addLine(to: CGPoint(x: w * 0.68, y: h * 0.56))
            crown.closeSubpath()
            ctx.fill(crown, with: .color(straw))
            // Cinta.
            let band = Path(CGRect(x: w * 0.33, y: h * 0.46, width: w * 0.34, height: h * 0.07))
            ctx.fill(band, with: .color(Color(hex: "#8A1E1E")))
        }
        .frame(width: size, height: size)
    }
}

// MARK: Creamfields — la hélice de Cream

private struct CreamMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: size * 0.045)
                .frame(width: size * 0.86, height: size * 0.86)
            // Tres aspas rectas a 120°, como el emblema clásico.
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: size * 0.10, height: size * 0.34)
                    .offset(y: -size * 0.17)
                    .rotationEffect(.degrees(Double(i) * 120))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Primavera Sound — el zigzag

private struct ZigzagMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, cg in
            let w = cg.width, h = cg.height
            var p = Path()
            let midY = h * 0.5
            let amp = h * 0.16
            let steps = 6
            p.move(to: CGPoint(x: w * 0.10, y: midY + amp))
            for i in 1...steps {
                let x = w * 0.10 + (w * 0.80) * CGFloat(i) / CGFloat(steps)
                let y = midY + (i.isMultiple(of: 2) ? amp : -amp)
                p.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(p, with: .color(.white),
                       style: StrokeStyle(lineWidth: h * 0.075, lineCap: .round, lineJoin: .miter))
        }
        .frame(width: size, height: size)
    }
}

// MARK: Womad — la O de mundo

private struct WomadMark: View {
    let size: CGFloat

    var body: some View {
        VStack(spacing: size * 0.02) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: size * 0.04)
                // Meridianos y paralelo.
                Ellipse()
                    .strokeBorder(.white, lineWidth: size * 0.03)
                    .frame(width: size * 0.22, height: size * 0.44)
                Rectangle()
                    .fill(.white)
                    .frame(height: size * 0.03)
                    .padding(.horizontal, size * 0.03)
            }
            .frame(width: size * 0.44, height: size * 0.44)
            Text("WOMAD")
                .font(.system(size: size * 0.16, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: Fauna Primavera — la mancha con el nombre

private struct FaunaMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            BlobShape()
                .fill(Color(hex: "#3B30E8"))
                .frame(width: size * 0.92, height: size * 0.80)
            Text("FAUNA")
                .font(.system(size: size * 0.20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-6))
        }
        .frame(width: size, height: size)
    }
}

/// Mancha orgánica de bordes redondeados (el "splat" del afiche de Fauna).
private struct BlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.20, y: h * 0.30))
        p.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.08), control: CGPoint(x: w * 0.30, y: h * 0.02))
        p.addQuadCurve(to: CGPoint(x: w * 0.92, y: h * 0.30), control: CGPoint(x: w * 0.85, y: h * 0.05))
        p.addQuadCurve(to: CGPoint(x: w * 0.82, y: h * 0.72), control: CGPoint(x: w * 1.02, y: h * 0.55))
        p.addQuadCurve(to: CGPoint(x: w * 0.42, y: h * 0.94), control: CGPoint(x: w * 0.68, y: h * 1.02))
        p.addQuadCurve(to: CGPoint(x: w * 0.06, y: h * 0.68), control: CGPoint(x: w * 0.12, y: h * 0.95))
        p.addQuadCurve(to: CGPoint(x: w * 0.20, y: h * 0.30), control: CGPoint(x: -w * 0.02, y: h * 0.38))
        p.closeSubpath()
        return p
    }
}

// MARK: Muda — letras geométricas

private struct MudaMark: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.015) {
            letter("M", Color(hex: "#F2A0A0"))
            letter("U", Color(hex: "#D96A2B"))
            letter("D", Color(hex: "#C2451F"))
            // La A del logo es un triángulo rosado.
            TriangleShape()
                .fill(Color(hex: "#F2A0A0"))
                .frame(width: size * 0.20, height: size * 0.26)
        }
        .frame(width: size, height: size)
    }

    private func letter(_ ch: String, _ color: Color) -> some View {
        Text(ch)
            .font(.system(size: size * 0.26, weight: .black, design: .rounded))
            .foregroundStyle(color)
    }
}

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: Bamba — letras de colores

private struct BambaMark: View {
    let size: CGFloat
    private let colors: [Color] = [
        Color(hex: "#E63946"), Color(hex: "#F28CB1"), Color(hex: "#2A9D4A"),
        Color(hex: "#2D6CDF"), Color(hex: "#F2C931"),
    ]

    var body: some View {
        HStack(spacing: size * 0.005) {
            ForEach(Array("BAMBA".enumerated()), id: \.offset) { i, ch in
                Text(String(ch))
                    .font(.system(size: size * 0.26, weight: .black, design: .rounded))
                    .foregroundStyle(colors[i % colors.count])
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Ruidosa — la R rayada en cursiva

private struct RuidosaMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // Copias desplazadas que insinúan el contorno rayado del logo.
            ForEach(0..<3, id: \.self) { i in
                Text("R")
                    .font(.system(size: size * 0.52, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(i == 2 ? Color(hex: "#F24C9E") : Color(hex: "#F24C9E").opacity(0.35))
                    .offset(x: CGFloat(2 - i) * size * 0.035, y: 0)
            }
            Text("FEST")
                .font(.system(size: size * 0.13, weight: .heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, size * 0.035)
                .padding(.vertical, size * 0.012)
                .background(Color(hex: "#F2C931"))
                .rotationEffect(.degrees(-8))
                .offset(x: size * 0.16, y: size * 0.24)
        }
        .frame(width: size, height: size)
    }
}

// MARK: Frontera — wordmark angular con cenefa

private struct FronteraMark: View {
    let size: CGFloat

    var body: some View {
        VStack(spacing: size * 0.04) {
            VStack(spacing: -size * 0.03) {
                Text("FRON")
                Text("TERA")
            }
            .font(.system(size: size * 0.24, weight: .black))
            .foregroundStyle(.black)
            // La cenefa triangular de sus afiches.
            ZigzagLine()
                .stroke(.black, style: StrokeStyle(lineWidth: size * 0.035, lineJoin: .miter))
                .frame(width: size * 0.56, height: size * 0.08)
        }
        .frame(width: size, height: size)
    }
}

private struct ZigzagLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 4
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for i in 1...steps {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
            let y = i.isMultiple(of: 2) ? rect.maxY : rect.minY
            p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }
}

// MARK: La Cumbre del Rock Chileno — el escudo con la estrella

private struct CumbreMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            ShieldShape().fill(Color(hex: "#12356B"))
            // Mitad inferior roja, recortada por el propio escudo.
            ShieldShape()
                .fill(Color(hex: "#D42B2B"))
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: size * 0.30)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            ShieldShape().strokeBorder(.white, lineWidth: size * 0.035)
            StarShape()
                .fill(.white)
                .frame(width: size * 0.26, height: size * 0.26)
                .offset(y: -size * 0.08)
        }
        .frame(width: size * 0.62, height: size * 0.68)
    }
}

/// Escudo tipo blasón deportivo, con InsettableShape para poder trazar borde.
private struct ShieldShape: InsettableShape {
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> ShieldShape {
        var s = self; s.inset += amount; return s
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.12))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.12))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY),
                       control: CGPoint(x: r.maxX, y: r.maxY * 0.92))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.midY),
                       control: CGPoint(x: r.minX, y: r.maxY * 0.92))
        p.closeSubpath()
        return p
    }
}

private struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rOut = min(rect.width, rect.height) / 2
        let rIn = rOut * 0.4
        var p = Path()
        for i in 0..<10 {
            let angle = Angle(degrees: Double(i) * 36 - 90).radians
            let r = i.isMultiple(of: 2) ? rOut : rIn
            let pt = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: Santiago Gets Louder — la bandera

private struct SGLMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Canvas { ctx, cg in
                let w = cg.width, h = cg.height
                // Mástil inclinado.
                var pole = Path()
                pole.move(to: CGPoint(x: w * 0.24, y: h * 0.86))
                pole.addLine(to: CGPoint(x: w * 0.30, y: h * 0.14))
                ctx.stroke(pole, with: .color(.white),
                           style: StrokeStyle(lineWidth: w * 0.045, lineCap: .round))
                // Paño flameado.
                var flag = Path()
                flag.move(to: CGPoint(x: w * 0.30, y: h * 0.16))
                flag.addQuadCurve(to: CGPoint(x: w * 0.86, y: h * 0.24),
                                  control: CGPoint(x: w * 0.60, y: h * 0.06))
                flag.addLine(to: CGPoint(x: w * 0.82, y: h * 0.58))
                flag.addQuadCurve(to: CGPoint(x: w * 0.27, y: h * 0.50),
                                  control: CGPoint(x: w * 0.56, y: h * 0.66))
                flag.closeSubpath()
                ctx.fill(flag, with: .color(.white))
            }
            Text("SGL")
                .font(.system(size: size * 0.20, weight: .black))
                .foregroundStyle(.black)
                .rotationEffect(.degrees(6))
                .offset(x: size * 0.06, y: -size * 0.13)
        }
        .frame(width: size, height: size)
    }
}

// MARK: Maquinaria — el engranaje

private struct GearMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            GearShape()
                .fill(.white)
                .frame(width: size * 0.72, height: size * 0.72)
            Text("M")
                .font(.system(size: size * 0.30, weight: .black))
                .foregroundStyle(Color(hex: "#5A0E0E"))
        }
        .frame(width: size, height: size)
    }
}

/// Engranaje de ocho dientes con perforación implícita (la M va encima).
private struct GearShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rBody = min(rect.width, rect.height) * 0.38
        let rTooth = min(rect.width, rect.height) * 0.5
        var p = Path()
        let teeth = 8
        let step = 360.0 / Double(teeth)
        for i in 0..<teeth {
            let base = Double(i) * step
            // Arco del cuerpo entre dientes.
            p.addArc(center: c, radius: rBody,
                     startAngle: .degrees(base + step * 0.30),
                     endAngle: .degrees(base + step * 0.70),
                     clockwise: false)
            // Diente: dos radios cortos hacia el radio exterior.
            let a0 = Angle(degrees: base + step * 0.78).radians
            let a1 = Angle(degrees: base + step * 1.02).radians
            p.addLine(to: CGPoint(x: c.x + cos(a0) * rTooth, y: c.y + sin(a0) * rTooth))
            p.addArc(center: c, radius: rTooth,
                     startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            p.addLine(to: CGPoint(x: c.x + cos(Angle(degrees: base + step * 1.30).radians) * rBody,
                                  y: c.y + sin(Angle(degrees: base + step * 1.30).radians) * rBody))
        }
        p.closeSubpath()
        return p
    }
}
