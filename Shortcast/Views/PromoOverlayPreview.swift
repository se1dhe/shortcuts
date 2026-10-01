import SwiftUI
import AppKit

/// Live SwiftUI preview of the RedQueen Security promo chip shown at the top of the video.
/// Mirrors `PromoOverlayRenderer`: a slim glass chip with a crimson shield, a breathing
/// halo and a specular light sweep. `promoCode` is accepted for call-site compatibility.
struct PromoOverlayPreview: View {
    let promoCode: String
    let w: CGFloat

    // RedQueen crimson palette.
    private let crimson = Color(red: 0.80, green: 0.12, blue: 0.16)
    private let crimsonLight = Color(red: 0.95, green: 0.26, blue: 0.30)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let slide = min(1, max(0, t.truncatingRemainder(dividingBy: 10) / 0.5))
            let pulse = 0.35 + 0.55 * (0.5 + 0.5 * sin(t * .pi * 2 / 2.4))
            let sweepPhase = (t.truncatingRemainder(dividingBy: 3.2)) / 3.2

            VStack(spacing: 0) {
                chip(pulse: pulse, sweepPhase: sweepPhase)
                    .offset(y: -w * 0.17 * (1 - slide))
                    .opacity(slide)
                    .padding(.top, w * 0.045)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func icon(_ h: CGFloat) -> some View {
        if NSImage(named: "BotAvatar") != nil {
            Image("BotAvatar")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: h * 0.66, height: h * 0.66)
                .clipShape(Circle())
                .overlay(Circle().stroke(crimsonLight, lineWidth: max(1, h * 0.05)))
        } else {
            ShieldMark(check: true)
                .fill(LinearGradient(colors: [crimsonLight, crimson,
                                              Color(red: 0.42, green: 0.04, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(ShieldMark(check: true).stroke(.white.opacity(0.25), lineWidth: 1))
                .frame(width: h * 0.55, height: h * 0.66)
        }
    }

    @ViewBuilder
    private func chip(pulse: Double, sweepPhase: Double) -> some View {
        let h = w * 0.17
        let corner = h * 0.32

        HStack(spacing: h * 0.22) {
            icon(h)

            VStack(alignment: .leading, spacing: h * 0.03) {
                Text("RedQueen Security")
                    .font(.system(size: h * 0.225, weight: .heavy))
                    .foregroundStyle(.white)
                Text("Умная AI-модерация Telegram-чатов")
                    .font(.system(size: h * 0.145, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Text("@RedQueenSecurity_Bot · капча · антиспам")
                    .font(.system(size: h * 0.135, weight: .semibold))
                    .foregroundStyle(crimsonLight)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, h * 0.26)
        .frame(width: w * 0.92, height: h)
        .background(
            ZStack {
                Color(red: 0.05, green: 0.02, blue: 0.03).opacity(0.82)
                RadialGradient(colors: [crimson.opacity(0.55), .clear],
                               center: UnitPoint(x: 0.12, y: 0.5),
                               startRadius: 0, endRadius: w * 0.5)
                // Specular sweep.
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.28)
                    .rotationEffect(.degrees(-18))
                    .offset(x: (sweepPhase * 1.6 - 0.5) * w * 0.9)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner)
            .stroke(crimsonLight.opacity(0.55), lineWidth: max(1, w * 0.0035)))
        .shadow(color: crimsonLight.opacity(pulse), radius: w * 0.03)
    }
}

/// A downward-pointing shield outline matching the renderer's burned-in mark.
private struct ShieldMark: Shape {
    var check: Bool = false

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.60))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY),
                       control: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.12))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.60),
                       control: CGPoint(x: r.minX, y: r.maxY - r.height * 0.12))
        p.closeSubpath()
        return p
    }
}
