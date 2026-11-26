import SwiftUI
import AppKit

// Zephyr icon: a translucent glass fan rotor over a cool-to-warm thermal field.
// Renders three PNGs: full icon (macOS template), background layer, glass foreground layer.

struct Blade: Shape {
    func path(in r: CGRect) -> Path {
        // One curved blade pointing up from the hub, swept to the right.
        var p = Path()
        let w = r.width, h = r.height
        let c = CGPoint(x: r.midX, y: r.midY)
        let inner = w * 0.085, outer = w * 0.44
        func pt(_ radius: CGFloat, _ ang: CGFloat) -> CGPoint { CGPoint(x: c.x + radius * cos(ang), y: c.y + radius * sin(ang)) }
        let a0 = -CGFloat.pi / 2
        p.move(to: pt(inner, a0 - 0.22))
        p.addCurve(to: pt(outer, a0 + 0.10),
                   control1: pt(w * 0.20, a0 - 0.55), control2: pt(w * 0.36, a0 - 0.40))
        p.addCurve(to: pt(outer * 0.97, a0 + 0.50),
                   control1: pt(outer * 1.05, a0 + 0.28), control2: pt(outer * 1.04, a0 + 0.40))
        p.addCurve(to: pt(inner, a0 + 0.42),
                   control1: pt(w * 0.30, a0 + 0.36), control2: pt(w * 0.16, a0 + 0.50))
        p.closeSubpath()
        _ = h
        return p
    }
}

struct GlassFan: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let rot = Angle.degrees(Double(i) * 360.0 / 7.0)
                ZStack {
                    Blade().fill(LinearGradient(colors: [.white.opacity(0.62), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom))
                    Blade().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .center))
                    Blade().stroke(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: size * 0.006)
                }
                .shadow(color: .black.opacity(0.22), radius: size * 0.014, x: 0, y: size * 0.008)
                .rotationEffect(rot)
            }
            // Hub: a small glass lens
            Circle().fill(LinearGradient(colors: [.white, .white.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.17, height: size * 0.17)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: size * 0.004))
                .shadow(color: .black.opacity(0.3), radius: size * 0.014, y: size * 0.008)
            Circle().fill(RadialGradient(colors: [Color(red: 0.25, green: 0.55, blue: 1).opacity(0.9), Color(red: 0.1, green: 0.3, blue: 0.9).opacity(0.9)], center: .topLeading, startRadius: 0, endRadius: size * 0.05))
                .frame(width: size * 0.07, height: size * 0.07)
        }
        .frame(width: size, height: size)
    }
}

struct Background: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.10, blue: 0.22), Color(red: 0.02, green: 0.03, blue: 0.09)], startPoint: .top, endPoint: .bottom)
            // cool glow, upper left
            Circle().fill(Color(red: 0.18, green: 0.55, blue: 1.0)).frame(width: size * 0.95).blur(radius: size * 0.16)
                .offset(x: -size * 0.22, y: -size * 0.24).opacity(0.85)
            // warm glow, lower right: the "heat" the fan is moving away
            Circle().fill(Color(red: 1.0, green: 0.45, blue: 0.18)).frame(width: size * 0.8).blur(radius: size * 0.15)
                .offset(x: size * 0.30, y: size * 0.34).opacity(0.80)
            Circle().fill(Color(red: 0.62, green: 0.30, blue: 1.0)).frame(width: size * 0.5).blur(radius: size * 0.13)
                .offset(x: size * 0.28, y: -size * 0.05).opacity(0.35)
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

struct Squircle: Shape {
    func path(in r: CGRect) -> Path { Path(roundedRect: r, cornerRadius: r.width * 0.2237, style: .continuous) }
}

struct FullIcon: View {
    var body: some View {
        let body = CGFloat(824)
        ZStack {
            Background(size: body)
                .overlay(
                    // glass sheen across the top half
                    LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.0)], startPoint: .top, endPoint: .center)
                )
                .overlay(
                    Squircle().stroke(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.05), .white.opacity(0.25)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
                )
                .clipShape(Squircle())
                .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 14)
                .frame(width: body, height: body)
            GlassFan(size: body * 0.86)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render<V: View>(_ v: V, to path: String, size: CGFloat = 1024) {
    let r = ImageRenderer(content: v.frame(width: size, height: size))
    r.scale = 1
    guard let cg = r.cgImage else { print("render failed"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

@main struct Main {
    @MainActor static func main() {
        let out = CommandLine.arguments[1]
        render(FullIcon(), to: "\(out)/icon_1024.png")
        render(Background(size: 1024), to: "\(out)/layer_background.png")
        render(GlassFan(size: 1024 * 0.86), to: "\(out)/layer_glass_fan.png")
    }
}
