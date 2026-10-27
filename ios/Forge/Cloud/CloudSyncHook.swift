import SwiftUI

extension AppModel {
    /// The integrations that feed Supabase, built from the existing cached data (read-only).
    var cloudIntegrations: [any Integration] {
        [HevyIntegration(workouts: workouts), HealthKitIntegration(health: health)]
    }
}

extension CloudSync {
    /// Pushes the app's current data. Sample (demo) data is never uploaded.
    func push(from model: AppModel) async {
        guard !model.demoMode, !model.isSyncing else { return }
        await sync(model.cloudIntegrations)
    }
}

/// Attach once at the root with `.cloudSync()`. Pushes to Supabase on launch, after every existing
/// refresh (launch, foreground, pull-to-refresh) and right after sign-in, without changing the existing sync code.
private struct CloudSyncHook: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var cloud = CloudSync()

    func body(content: Content) -> some View {
        content
            .environment(cloud)
            .task { await cloud.push(from: model) }
            .onChange(of: model.isSyncing) { _, syncing in
                if !syncing { Task { await cloud.push(from: model) } }
            }
            .onChange(of: cloud.isSignedIn) { _, signedIn in
                if signedIn { Task { await cloud.push(from: model) } }
            }
    }
}

extension View {
    func cloudSync() -> some View { modifier(CloudSyncHook()) }
}
