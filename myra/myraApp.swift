import SwiftUI
import UserNotifications
import BackgroundTasks

@main
struct MyraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // myra://connected after the Oura OAuth dance.
                    if url.host == "connected" {
                        Task { await AppState.shared.refreshAll() }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await AppState.shared.refreshAll() }
            } else if phase == .background {
                scheduleBackgroundRefresh()
            }
        }
    }

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.shaunak.myra.refresh", using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            scheduleBackgroundRefresh()
            let work = Task {
                // Sync sensors and enforce the current shield policy even when
                // the app isn't open.
                await HealthKitManager.shared.syncDailyAggregates(days: 2)
                await CalendarManager.shared.sync()
                if let policy = try? await APIClient.shared.directives() {
                    ScreenTimeManager.shared.enforce(policy: policy)
                }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }

        // Longer-running budget for heavy on-device generation (the weekly
        // report's multi-tool reasoning loop can exceed the silent-push window).
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.shaunak.myra.agent", using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            let work = Task {
                let engine = AgentEngine.current
                if engine != .backendClaude, MyraAgent.isAvailable {
                    for kind in AgentJobQueue.pending() {
                        try? await MyraAgent.shared.handleScheduledJob(kind: kind, engine: engine)
                        AgentJobQueue.clear(kind)
                    }
                }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.shaunak.myra.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// A tiny UserDefaults-backed queue of scheduled jobs deferred to a
/// BGProcessingTask when the silent-push window is too short (e.g. weekly).
enum AgentJobQueue {
    private static let key = "pendingAgentJobs"

    static func enqueue(_ kind: String) {
        var set = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        set.insert(kind)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    static func pending() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear(_ kind: String) {
        var set = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        set.remove(kind)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: "com.shaunak.myra.agent")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let granted = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            if granted == true {
                await MainActor.run { application.registerForRemoteNotifications() }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await APIClient.shared.registerDevice(token: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error)")
    }

    /// Silent/background push from the scheduler asking the on-device Apple
    /// Foundation Models agent to generate a scheduled job. Light jobs run
    /// inline; the heavy weekly report defers to a BGProcessingTask. If the
    /// device can't help (Apple Intelligence off, or still on Claude), we do
    /// nothing and the server's Claude fallback delivers the notification.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    ) async -> UIBackgroundFetchResult {
        guard let kind = userInfo["kind"] as? String else { return .noData }
        let engine = AgentEngine.current
        guard engine != .backendClaude, MyraAgent.isAvailable else { return .noData }

        if kind == "weekly" {
            AgentJobQueue.enqueue(kind)
            AgentJobQueue.scheduleProcessing()
            return .newData
        }

        do {
            try await MyraAgent.shared.handleScheduledJob(kind: kind, engine: engine)
            return .newData
        } catch {
            print("on-device job \(kind) failed: \(error)")
            return .failed
        }
    }

    // Show notifications while the app is in the foreground too.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
    ) async {
        await AppState.shared.refreshAll()
    }
}
