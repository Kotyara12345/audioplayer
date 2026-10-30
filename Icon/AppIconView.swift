import SwiftUI

struct AppIconView: View {
    enum Appearance: String, CaseIterable {
        case light, dark
    }

    let appearance: Appearance
    let size: CGFloat
    private let barHeights: [CGFloat] = [0.55, 0.85, 1.0, 0.72, 0.48]

    init(appearance: Appearance, size: CGFloat) {
        self.appearance = appearance
        self.size = size
    }

    var body: some View {
        ZStack {
            backgroundGradient
            ambientGlow
            glassSquare
            equalizerBars
        }
        .frame(width: size, height: size)
        .clipped()
    }

    private var backgroundGradient: some View {
        let colors: [Color] = appearance == .light
            ? [Color(red: 0.30, green: 0.55, blue: 1.00),
               Color(red: 0.36, green: 0.30, blue: 0.95),
               Color(red: 0.20, green: 0.12, blue: 0.70)]
            : [Color(red: 0.04, green: 0.06, blue: 0.16),
               Color(red: 0.08, green: 0.05, blue: 0.22),
               Color(red: 0.02, green: 0.02, blue: 0.08)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var ambientGlow: some View {
        RadialGradient(
            colors: [appearance == .light
                     ? .white.opacity(0.35)
                     : Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.20),
                     .clear],
            center: .init(x: 0.25, y: 0.20),
            startRadius: 0, endRadius: size * 0.55)
    }

    private var glassSquare: some View {
        let inset = size * 0.14
        let corner = size * 0.20

        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(
                stops: [
                    .init(color: .white.opacity(appearance == .light ? 0.30 : 0.12), location: 0),
                    .init(color: .white.opacity(appearance == .light ? 0.10 : 0.04), location: 0.55),
                    .init(color: .white.opacity(appearance == .light ? 0.05 : 0.02), location: 1)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.85), location: 0),
                            .init(color: .white.opacity(0.35), location: 0.35),
                            .init(color: .white.opacity(0.05), location: 0.7),
                            .init(color: .white.opacity(0.20), location: 1)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: size * 0.006)
            }
            .overlay(alignment: .topLeading) {
                Ellipse()
                    .fill(.white.opacity(appearance == .light ? 0.35 : 0.18))
                    .frame(width: size * 0.45, height: size * 0.22)
                    .blur(radius: size * 0.07)
                    .offset(x: size * 0.06, y: size * 0.06)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
            .shadow(color: .black.opacity(appearance == .light ? 0.25 : 0.55),
                    radius: size * 0.035, x: 0, y: size * 0.02)
            .shadow(color: appearance == .dark
                    ? Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.35) : .clear,
                    radius: size * 0.05)
            .padding(inset)
    }

    private var equalizerBars: some View {
        let w = size * 0.085
        let sp = size * 0.038
        let maxH = size * 0.44
        let corner = w * 0.40

        return HStack(alignment: .bottom, spacing: sp) {
            ForEach(0..<barHeights.count, id: \.self) { i in
                let h = maxH * barHeights[i]
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(stops: [
                        .init(color: appearance == .light ? .white
                              : Color(red: 0.75, green: 0.95, blue: 1.0), location: 0),
                        .init(color: appearance == .light
                              ? Color(red: 0.85, green: 0.92, blue: 1.0)
                              : Color(red: 0.35, green: 0.75, blue: 1.0), location: 0.5),
                        .init(color: appearance == .light
                              ? Color(red: 0.65, green: 0.80, blue: 1.0)
                              : Color(red: 0.20, green: 0.55, blue: 0.95), location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.95))
                            .frame(width: w * 0.55, height: w * 0.18)
                            .padding(.top, w * 0.12)
                            .blur(radius: w * 0.08)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(.white.opacity(0.45), lineWidth: size * 0.0018)
                    }
                    .shadow(color: appearance == .dark
                            ? Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.55)
                            : .black.opacity(0.15),
                            radius: size * 0.018, x: 0, y: size * 0.005)
                    .frame(width: w, height: h)
            }
        }
        .frame(height: maxH, alignment: .bottom)
    }
}