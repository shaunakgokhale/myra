import SwiftUI

/// Guided 4-7-8 breathing session (2 minutes). Logged back to HealthKit as
/// mindfulness when completed, so the stats engine can see whether it helps.
struct BreathingView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Phase: String {
        case inhale = "Breathe in"
        case hold = "Hold"
        case exhale = "Breathe out"
    }

    @State private var phase: Phase = .inhale
    @State private var scale: CGFloat = 0.55
    @State private var secondsLeft = 120
    @State private var sessionStart = Date.now
    @State private var running = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 40) {
                Text(running ? phase.rawValue : "4-7-8 breathing")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.opacity)

                ZStack {
                    Circle()
                        .fill(Theme.sleep.opacity(0.12))
                        .frame(width: 260, height: 260)
                    Circle()
                        .fill(
                            RadialGradient(colors: [Theme.sleep.opacity(0.8), Theme.hrv.opacity(0.4)], center: .center, startRadius: 10, endRadius: 130)
                        )
                        .frame(width: 240, height: 240)
                        .scaleEffect(scale)
                }

                Text(running ? timeString : "2 minutes. In 4 · hold 7 · out 8.")
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()

                Button {
                    running ? finish(completed: false) : start()
                } label: {
                    Text(running ? "End early" : "Start")
                        .font(.headline)
                        .frame(maxWidth: 220)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(running ? Theme.warning : Theme.sleep)
            }
        }
        .task(id: running) {
            guard running else { return }
            await breathingLoop()
        }
    }

    private var timeString: String {
        "\(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))"
    }

    private func start() {
        sessionStart = .now
        secondsLeft = 120
        running = true
    }

    private func finish(completed: Bool) {
        running = false
        let start = sessionStart
        if completed || Date.now.timeIntervalSince(start) > 45 {
            Task { await HealthKitManager.shared.logMindfulSession(start: start, end: .now) }
        }
        dismiss()
    }

    private func breathingLoop() async {
        let cycle: [(Phase, Double, CGFloat)] = [
            (.inhale, 4, 1.0),
            (.hold, 7, 1.0),
            (.exhale, 8, 0.55),
        ]
        let ticker = Task {
            while secondsLeft > 0 && running {
                try await Task.sleep(for: .seconds(1))
                secondsLeft -= 1
            }
        }
        outer: while running && secondsLeft > 0 {
            for (p, duration, target) in cycle {
                guard running, secondsLeft > 0 else { break outer }
                phase = p
                withAnimation(.easeInOut(duration: duration)) { scale = target }
                try? await Task.sleep(for: .seconds(duration))
            }
        }
        ticker.cancel()
        if secondsLeft <= 0 { finish(completed: true) }
    }
}
