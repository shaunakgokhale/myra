import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import SwiftUI

/// Screen Time enforcement: shields the apps you pick once your wind-down time
/// arrives, with strictness driven by the backend's shield policy (which the
/// agent scales to your sleep debt).
@Observable
final class ScreenTimeManager {
    static let shared = ScreenTimeManager()

    private let store = ManagedSettingsStore(named: .init("myra.winddown"))
    var isAuthorized = false
    var selection = FamilyActivitySelection() {
        didSet { saveSelection() }
    }
    var shieldActive = false

    init() {
        loadSelection()
    }

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            isAuthorized = true
        } catch {
            print("FamilyControls auth failed: \(error)")
        }
    }

    private func saveSelection() {
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: "shieldSelection")
        }
    }

    private func loadSelection() {
        if let data = UserDefaults.standard.data(forKey: "shieldSelection"),
           let sel = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selection = sel
        }
    }

    /// Apply or lift the shield according to the current policy and local time.
    /// Called on app launch/foreground, after notification taps, and from background refresh.
    func enforce(policy: ShieldPolicy?) {
        guard isAuthorized, let policy, policy.strictness > 0, !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty else {
            liftShield()
            return
        }

        let parts = policy.winddownTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        var winddownMinutes = parts[0] * 60 + parts[1]
        // Strict mode starts 45 minutes earlier.
        if policy.strictness >= 2 { winddownMinutes -= 45 }

        let now = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let nowMinutes = (now.hour ?? 0) * 60 + (now.minute ?? 0)

        // Shield window: winddown -> 05:00.
        let inWindow = nowMinutes >= winddownMinutes || nowMinutes < 5 * 60
        if inWindow {
            applyShield()
        } else {
            liftShield()
        }
    }

    private func applyShield() {
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
        shieldActive = true
    }

    func liftShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        shieldActive = false
    }
}
