import SwiftUI
import OrreryRemoteClient

@main
struct OrreryRemoteApp: App {
    @StateObject private var hub = RemoteHub()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RemoteDashboard(hub: hub)
                .tint(.purple)
                .overlay {
                    if scenePhase != .active { Color(.systemBackground).ignoresSafeArea().overlay(Image(systemName: "lock.shield").font(.largeTitle)) }
                }
                .task { hub.setActive(true) }
                .onChange(of: scenePhase) { _, phase in hub.setActive(phase == .active) }
        }
    }
}
