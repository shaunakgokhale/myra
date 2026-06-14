import SwiftUI
import FamilyControls

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage("backendURL") private var backendURL = ""
    @AppStorage("appToken") private var appToken = ""
    @AppStorage("agentEngine") private var agentEngine = AgentEngine.backendClaude.rawValue
    @State private var health = HealthKitManager.shared
    @State private var calendar = CalendarManager.shared
    @State private var screenTime = ScreenTimeManager.shared
    @State private var showAppPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("Backend") {
                    TextField("Backend URL", text: $backendURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField("App token", text: $appToken)
                    LabeledContent("Oura") {
                        if state.status?.ouraConnected == true {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.readiness)
                        } else if let url = (state.status?.oauthStartUrl).flatMap(URL.init) {
                            Link("Connect", destination: url)
                        } else {
                            Text("—")
                        }
                    }
                    LabeledContent("AI agent") {
                        Text(state.status?.agentConfigured == true ? "Ready" : "No API key")
                            .foregroundStyle(state.status?.agentConfigured == true ? Theme.readiness : Theme.warning)
                    }
                    LabeledContent("Latest Oura day") {
                        Text(state.status?.latestOuraDay ?? "—")
                    }
                }

                Section {
                    Picker("Engine", selection: $agentEngine) {
                        Text("Claude (backend)").tag(AgentEngine.backendClaude.rawValue)
                        Text("Shadow (compare)").tag(AgentEngine.shadow.rawValue)
                        Text("Apple on-device").tag(AgentEngine.onDeviceApple.rawValue)
                    }
                    .onChange(of: agentEngine) { _, newValue in
                        Task { try? await APIClient.shared.setAgentEngine(newValue) }
                    }
                    LabeledContent("Apple Intelligence") {
                        Text(MyraAgent.isAvailable ? "Available" : "Unavailable")
                            .foregroundStyle(MyraAgent.isAvailable ? Theme.readiness : Theme.warning)
                    }
                } header: {
                    Text("Intelligence engine")
                } footer: {
                    Text("Claude runs the agent on the backend. Shadow keeps Claude live while the on-device Apple model generates a parallel copy you can compare in the Lab. Apple on-device makes the phone's Foundation Models the primary brain, with Claude as a safety fallback if the phone can't respond in time.")
                }

                Section("Data sources") {
                    permissionRow("HealthKit", granted: health.isAuthorized) {
                        Task { await health.requestAuthorization() }
                    }
                    permissionRow("Calendar", granted: calendar.isAuthorized) {
                        Task { await calendar.requestAccess() }
                    }
                    permissionRow("Screen Time", granted: screenTime.isAuthorized) {
                        Task { await screenTime.requestAuthorization() }
                    }
                }

                Section {
                    Button("Choose apps to shield at wind-down") {
                        showAppPicker = true
                    }
                    .disabled(!screenTime.isAuthorized)

                    if let policy = state.dashboard.shieldPolicy {
                        LabeledContent("Tonight's policy") {
                            Text(policy.strictness == 0 ? "Off" : "Level \(policy.strictness) from \(policy.winddownTime)")
                        }
                        if let reason = policy.reason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if screenTime.shieldActive {
                        Button("Lift shield (override)", role: .destructive) {
                            screenTime.liftShield()
                        }
                    }
                } header: {
                    Text("Wind-down shield")
                } footer: {
                    Text("Myra shields distracting apps after your computed wind-down time. Strictness scales with your sleep debt: the worse your recovery, the stricter your phone.")
                }

                Section("Sync") {
                    Button("Sync sensors now") {
                        Task {
                            await health.syncDailyAggregates()
                            await calendar.sync()
                            await state.refreshAll()
                        }
                    }
                    if let last = UserDefaults.standard.object(forKey: "lastHealthKitSync") as? Date {
                        LabeledContent("Last HealthKit sync") {
                            Text(last, style: .relative)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .familyActivityPicker(isPresented: $showAppPicker, selection: Binding(
                get: { screenTime.selection },
                set: { screenTime.selection = $0 }
            ))
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label("On", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.readiness)
            } else {
                Button("Enable", action: action)
            }
        }
    }
}
