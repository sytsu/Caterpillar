// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppSettings.shared.orientation.mask
    }

    /// Turn the interface to match the orientation setting.
    static func applyOrientation() {
        let mask = AppSettings.shared.orientation.mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}

@main
struct CaterpillarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var vm = VMController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(vm: vm)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        AppDelegate.applyOrientation()
                        vm.appBecameActive()
                    }
                }
                .onChange(of: vm.settings.orientation) { _, _ in AppDelegate.applyOrientation() }
        }
    }
}

/// Home until Windows is up, then the session.
struct RootView: View {
    @ObservedObject var vm: VMController

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.background.ignoresSafeArea()
                switch vm.phase {
                case .running, .stopped:
                    SessionView(vm: vm, settings: vm.settings)
                        .transition(.opacity)
                default:
                    HomeView(vm: vm, settings: vm.settings)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: vm.phase == .running)
            .onAppear { vm.updatePlan(bounds: fullSize(geo), insets: insets(geo)) }
            .onChange(of: geo.size) { _, _ in vm.updatePlan(bounds: fullSize(geo), insets: insets(geo)) }
            .onChange(of: vm.settings.resolution) { _, _ in vm.updatePlan(bounds: fullSize(geo), insets: insets(geo)) }
            .onChange(of: vm.settings.fit) { _, _ in vm.updatePlan(bounds: fullSize(geo), insets: insets(geo)) }
        }
    }

    /// The whole screen, safe-area margins included.
    private func fullSize(_ geo: GeometryProxy) -> CGSize {
        CGSize(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
               height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
    }

    private func insets(_ geo: GeometryProxy) -> UIEdgeInsets {
        UIEdgeInsets(top: geo.safeAreaInsets.top, left: geo.safeAreaInsets.leading,
                     bottom: geo.safeAreaInsets.bottom, right: geo.safeAreaInsets.trailing)
    }
}
