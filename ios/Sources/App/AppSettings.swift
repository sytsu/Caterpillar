// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// How many pixels Windows draws. Fewer pixels is faster: Windows renders everything on the CPU.
enum ResolutionPreset: String, CaseIterable, Identifiable {
    case fast, balanced, sharp, native, classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .sharp: return "Sharp"
        case .native: return "Native"
        case .classic: return "Classic 4:3"
        }
    }

    /// Target height in guest pixels; nil means "every pixel of the screen".
    var targetHeight: Int? {
        switch self {
        case .fast: return 720
        case .balanced: return 900
        case .sharp: return 1080
        case .native: return nil
        case .classic: return 768
        }
    }
}

/// Where the Windows picture sits in landscape.
enum DisplayFit: String, CaseIterable, Identifiable {
    case safe, edge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safe: return "Clear of the camera"
        case .edge: return "Fill the whole screen"
        }
    }
}

enum OrientationLock: String, CaseIterable, Identifiable {
    case auto, landscape, portrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Follow the device"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .auto: return UIDevice.current.userInterfaceIdiom == .phone ? .allButUpsideDown : .all
        case .landscape: return .landscape
        case .portrait: return .portrait
        }
    }
}

enum TouchMode: String, CaseIterable, Identifiable {
    case direct, trackpad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "Touch"
        case .trackpad: return "Trackpad"
        }
    }

    var symbol: String {
        switch self {
        case .direct: return "hand.point.up.left"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        }
    }
}

/// Settings, kept in UserDefaults. Display and machine settings are read when Windows starts.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let store = UserDefaults.standard

    @Published var resolution: ResolutionPreset { didSet { store.set(resolution.rawValue, forKey: "display.resolution") } }
    @Published var fit: DisplayFit { didSet { store.set(fit.rawValue, forKey: "display.fit") } }
    @Published var sharpPixels: Bool { didSet { store.set(sharpPixels, forKey: "display.sharpPixels") } }
    @Published var limitTo30: Bool { didSet { store.set(limitTo30, forKey: "display.limitTo30") } }
    @Published var showStats: Bool { didSet { store.set(showStats, forKey: "display.showStats") } }
    /// With the picture filling the screen the controls sit on top of Windows; they can fold away.
    @Published var controlsFolded: Bool { didSet { store.set(controlsFolded, forKey: "display.controlsFolded") } }
    @Published var orientation: OrientationLock { didSet { store.set(orientation.rawValue, forKey: "display.orientation") } }

    /// 0 means "as much as the device allows".
    @Published var ramMB: Int { didSet { store.set(ramMB, forKey: "machine.ramMB") } }
    @Published var cores: Int { didSet { store.set(cores, forKey: "machine.cores") } }

    @Published var touchMode: TouchMode { didSet { store.set(touchMode.rawValue, forKey: "input.touchMode") } }
    @Published var pointerSpeed: Double { didSet { store.set(pointerSpeed, forKey: "input.pointerSpeed") } }
    @Published var naturalScroll: Bool { didSet { store.set(naturalScroll, forKey: "input.naturalScroll") } }
    @Published var haptics: Bool { didSet { store.set(haptics, forKey: "input.haptics") } }

    @Published var autoStart: Bool { didSet { store.set(autoStart, forKey: "general.autoStart") } }
    @Published var guestLinksInSafari: Bool { didSet { store.set(guestLinksInSafari, forKey: "general.guestLinks") } }
    @Published var diagnostics: Bool { didSet { store.set(diagnostics, forKey: "general.diagnostics") } }

    private init() {
        resolution = ResolutionPreset(rawValue: store.string(forKey: "display.resolution") ?? "") ?? .fast
        fit = DisplayFit(rawValue: store.string(forKey: "display.fit") ?? "") ?? .safe
        sharpPixels = store.bool(forKey: "display.sharpPixels")
        limitTo30 = store.bool(forKey: "display.limitTo30")
        showStats = store.bool(forKey: "display.showStats")
        controlsFolded = store.bool(forKey: "display.controlsFolded")
        orientation = OrientationLock(rawValue: store.string(forKey: "display.orientation") ?? "") ?? .auto
        ramMB = store.integer(forKey: "machine.ramMB")
        cores = store.object(forKey: "machine.cores") as? Int ?? 4
        touchMode = TouchMode(rawValue: store.string(forKey: "input.touchMode") ?? "") ?? .direct
        pointerSpeed = store.object(forKey: "input.pointerSpeed") as? Double ?? 1.0
        naturalScroll = store.object(forKey: "input.naturalScroll") as? Bool ?? true
        haptics = store.object(forKey: "input.haptics") as? Bool ?? true
        autoStart = store.bool(forKey: "general.autoStart")
        guestLinksInSafari = store.object(forKey: "general.guestLinks") as? Bool ?? true
        diagnostics = store.bool(forKey: "general.diagnostics")
    }
}

/// The landscape area Windows fills, and the framebuffer size that matches its shape.
struct DisplayPlan: Equatable {
    /// Points, landscape.
    let area: CGSize
    let pixelWidth: Int
    let pixelHeight: Int

    var aspect: CGFloat { CGFloat(pixelWidth) / CGFloat(pixelHeight) }
    var label: String { "\(pixelWidth) × \(pixelHeight)" }

    /// `bounds` and `insets` may be given in either orientation; the plan is always for landscape.
    static func make(resolution: ResolutionPreset, fit: DisplayFit, bounds: CGSize, insets: UIEdgeInsets,
                     scale: CGFloat, isPhone: Bool) -> DisplayPlan {
        let long = max(bounds.width, bounds.height)
        let short = min(bounds.width, bounds.height)

        if resolution == .classic {
            let h = short
            return DisplayPlan(area: CGSize(width: min(long, h * 4 / 3), height: h), pixelWidth: 1024, pixelHeight: 768)
        }

        // On a phone the camera housing and the rounded corners sit at the short edges. In portrait
        // that inset is reported at the top, in landscape at the left and right.
        let side: CGFloat = (fit == .safe && isPhone) ? max(insets.top, insets.left, insets.right) : 0
        let area = CGSize(width: long - 2 * side, height: short)

        let nativeHeight = Int((area.height * scale).rounded())
        var height = min(resolution.targetHeight ?? nativeHeight, nativeHeight)
        height = max(600, height) & ~1
        var width = Int((CGFloat(height) * area.width / area.height / 8).rounded()) * 8
        width = min(max(width, 800), 4096)
        return DisplayPlan(area: area, pixelWidth: width, pixelHeight: height)
    }
}
