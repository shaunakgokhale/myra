import SwiftUI

enum Theme {
    static let bg = Color(red: 0.04, green: 0.05, blue: 0.10)
    static let card = Color(red: 0.09, green: 0.11, blue: 0.18)
    static let cardBorder = Color.white.opacity(0.07)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)

    static let readiness = Color(red: 0.36, green: 0.84, blue: 0.66)
    static let sleep = Color(red: 0.45, green: 0.62, blue: 1.0)
    static let activity = Color(red: 1.0, green: 0.62, blue: 0.36)
    static let hrv = Color(red: 0.76, green: 0.54, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.45, blue: 0.45)

    static func scoreColor(_ score: Double) -> Color {
        if score >= 80 { return readiness }
        if score >= 65 { return Color(red: 0.95, green: 0.83, blue: 0.4) }
        return warning
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Theme.cardBorder, lineWidth: 1)
                    )
            )
    }
}

struct ScoreRing: View {
    let score: Double // 0-100
    let label: String
    let color: Color
    var size: CGFloat = 96

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: size * 0.09)
                Circle()
                    .trim(from: 0, to: min(1, score / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(score))")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: size, height: size)
            .animation(.spring(duration: 0.8), value: score)

            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
