import SwiftUI

struct RootView: View {
    @State private var state = AppState.shared
    @AppStorage("backendURL") private var backendURL = ""

    var body: some View {
        Group {
            if backendURL.isEmpty {
                OnboardingView()
            } else {
                TabView {
                    Tab("Today", systemImage: "sun.max.fill") { TodayView() }
                    Tab("Trends", systemImage: "chart.xyaxis.line") { TrendsView() }
                    Tab("Coach", systemImage: "bubble.left.and.text.bubble.right.fill") { CoachView() }
                    Tab("Lab", systemImage: "testtube.2") { LabView() }
                    Tab("Settings", systemImage: "gearshape.fill") { SettingsView() }
                }
                .tint(Theme.readiness)
            }
        }
        .environment(state)
        .task { await state.refreshAll() }
    }
}

struct OnboardingView: View {
    @AppStorage("backendURL") private var backendURL = ""
    @AppStorage("appToken") private var appToken = ""
    @State private var urlInput = ""
    @State private var tokenInput = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.readiness)
                Text("Myra")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your autonomous health agent.\nObserve. Discover. Intervene. Verify. Remember.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)

                VStack(spacing: 12) {
                    TextField("Backend URL (https://…railway.app)", text: $urlInput)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Theme.textPrimary)
                    SecureField("App token", text: $tokenInput)
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 24)

                Button {
                    backendURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    appToken = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await AppState.shared.refreshAll() }
                } label: {
                    Text("Connect")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.readiness)
                .disabled(urlInput.isEmpty)
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }
}
