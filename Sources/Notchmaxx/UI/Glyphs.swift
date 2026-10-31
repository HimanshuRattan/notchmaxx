import SwiftUI

/// Simple drawn marks so each provider is recognizable at 12 to 28 points without shipping
/// trademarked artwork.
struct ProviderGlyph: View {
    var provider: Provider
    var size: CGFloat = 22
    var plate = true

    var body: some View {
        ZStack {
            if plate {
                Circle().fill(Color.white.opacity(0.07))
                Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            }
            mark
                .frame(width: size * (plate ? 0.58 : 1), height: size * (plate ? 0.58 : 1))
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var mark: some View {
        switch provider {
        case .claude: Starburst().fill(Theme.accent(.claude))
        case .codex: Blossom().stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: max(size * 0.045, 0.9)))
        case .cursor: Cube().stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: max(size * 0.05, 1), lineJoin: .round))
        }
    }
}

struct Starburst: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let rays = 12
        for i in 0..<rays {
            let angle = Double(i) / Double(rays) * 2 * .pi + .pi / 24
            let length = radius * (i.isMultiple(of: 2) ? 1.0 : 0.78)
            let width = radius * 0.17
            let ray = Path(roundedRect: CGRect(x: -width / 2, y: radius * 0.12, width: width, height: length - radius * 0.12),
                           cornerRadius: width / 2)
            let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
            path.addPath(ray, transform: transform)
        }
        path.addEllipse(in: CGRect(x: center.x - radius * 0.2, y: center.y - radius * 0.2, width: radius * 0.4, height: radius * 0.4))
        return path
    }
}

struct Blossom: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3
            let petal = Path(roundedRect: CGRect(x: -radius * 0.26, y: -radius * 0.98, width: radius * 0.52, height: radius * 1.18),
                             cornerRadius: radius * 0.26)
            let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
            path.addPath(petal, transform: transform)
        }
        return path
    }
}

struct Cube: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let points = (0..<6).map { i -> CGPoint in
            let angle = Double(i) * .pi / 3 - .pi / 2
            return CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
        }
        var path = Path()
        path.addLines(points + [points[0]])
        path.move(to: c)
        path.addLine(to: points[0])
        path.move(to: c)
        path.addLine(to: points[2])
        path.move(to: c)
        path.addLine(to: points[4])
        return path
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    @StateObject private var on = Box(false)

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.35))
                    .scaleEffect(on.value ? 2.3 : 1)
                    .opacity(on.value ? 0 : 1)
            }
            Circle().fill(color)
        }
        .frame(width: 6, height: 6)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on.value = true }
        }
    }
}
