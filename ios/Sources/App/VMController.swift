// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

struct GuestLink: Identifiable {
    let id = UUID()
    let url: URL
}

/// What the app knows about the machine, and the few things it can ask of it.
@MainActor
final class VMController: ObservableObject {
    enum Phase: Equatable {
        case idle              // nothing running yet
        case waitingForJIT     // Start was tapped; waiting for the debugger to grant JIT
        case unpacking         // windows11.hvsparse is being expanded
        case starting          // the machine is being created
        case running
        case stopped(String)   // ran and ended; the reason
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var jitLive = false
    @Published private(set) var jitStatus = ""
    @Published private(set) var hasDisk = false
    @Published private(set) var diskDescription = ""
    @Published private(set) var hasFirmware = false
    @Published private(set) var bundledFirmware = false
    @Published private(set) var status = ""
    /// Something the app itself has to tell the user (as opposed to the machine's status line).
    @Published var notice: String?
    @Published private(set) var unpackProgress = 0.0
    @Published private(set) var guestSize = CGSize.zero
    @Published private(set) var fps = 0
    @Published private(set) var idlePercent = 0.0
    @Published private(set) var thermalLimited = false
    @Published private(set) var importing = false
    @Published private(set) var importProgress = 0.0
    @Published var importError: String?
    @Published var guestLink: GuestLink?
    @Published private(set) var plan: DisplayPlan?

    let settings = AppSettings.shared
    let isSimulator = WinIOSBridge.shared.isSimulator

    private let bridge = WinIOSBridge.shared
    private var ticker: Timer?
    private var fastTicker: Timer?
    private var lastFrames: UInt64 = 0
    private var wantsStart = false
    private var didAutoStart = false
    private var everRan = false

    init() {
        bridge.installTrapGuard()
        bridge.onStateChanged = { [weak self] in
            Task { @MainActor in self?.sync() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.everySecond() }
        }
        fastTicker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.everyQuarterSecond() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyDisplayOptions() }
        }
        sync()
    }

    var machineFolder: String { bridge.machineDirectory }
    var canStart: Bool {
        hasDisk && hasFirmware && phase != .running && phase != .unpacking && phase != .starting && !importing
    }
    var configuredRamMB: Int { Int(bridge.configuredRamMB) }
    var configuredCores: Int { Int(bridge.configuredCPUs) }

    // MARK: Display plan

    /// Works out the landscape area and framebuffer size from the screen the app is on.
    func updatePlan(bounds: CGSize, insets: UIEdgeInsets) {
        let next = DisplayPlan.make(resolution: settings.resolution, fit: settings.fit, bounds: bounds, insets: insets,
                                    scale: UIScreen.main.scale, isPhone: UIDevice.current.userInterfaceIdiom == .phone)
        if next != plan { plan = next }
    }

    // MARK: Lifecycle

    func appBecameActive() {
        if !bridge.isJITLive, bridge.isDebuggerAttached || isSimulator {
            _ = bridge.tryAcquireJIT(true)
        }
        sync()
        if settings.autoStart, !didAutoStart, phase == .idle, canStart, jitLive {
            didAutoStart = true
            start()
        }
    }

    func start() {
        guard canStart else { return }
        if case .stopped = phase {
            // The engine keeps one machine per launch.
            notice = "Close Caterpillar and open it again to start Windows once more."
            return
        }
        applyMachineSettings()
        if !bridge.isJITLive {
            _ = bridge.tryAcquireJIT(true)
        }
        if !bridge.isJITLive {
            wantsStart = true
            phase = .waitingForJIT
            requestJIT()
            sync()
            return
        }
        wantsStart = false
        bridge.prepareAndStart(with: nil)
        applyDisplayOptions()
        sync()
    }

    func cancelWaiting() {
        wantsStart = false
        if phase == .waitingForJIT { phase = .idle }
    }

    /// Hands the app to StikDebug, which attaches and answers the JIT requests, then returns here.
    func requestJIT() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var text = "stikjit://enable-jit?bundle-id=\(bundleID)&pid=\(getpid())"
        if let path = Bundle.main.path(forResource: "henge-jit", ofType: "js"),
           let script = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let b64 = script.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            text += "&script-data=\(b64)"
        }
        guard let url = URL(string: text) else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.notice = "StikDebug did not open. Install it and pair it with this device, then try again."
                self?.cancelWaiting()
            }
        }
    }

    private func applyMachineSettings() {
        if let plan {
            bridge.preferredWidth = UInt32(plan.pixelWidth)
            bridge.preferredHeight = UInt32(plan.pixelHeight)
        }
        bridge.preferredRamMB = UInt64(max(0, settings.ramMB))
        bridge.preferredCPUs = Int32(settings.cores)
        bridge.diagnosticsEnabled = settings.diagnostics
        bridge.useSafariForGuestLinks = settings.guestLinksInSafari
    }

    func applyDisplayOptions() {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        thermalLimited = hot
        bridge.setDisplayFPS(settings.limitTo30 || hot ? 30 : 60)
        bridge.setNearestFilter(settings.sharpPixels)
    }

    // MARK: Machine actions

    func shutDown() { bridge.pressPowerButton() }

    func forceStop() {
        bridge.flushDisks()
        bridge.stopVM()
    }

    func saveScreenshot() -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let file = folder.appendingPathComponent("Windows \(f.string(from: Date())).png")
        return bridge.saveScreenshot(toPath: file.path)
    }

    // MARK: Disk image import

    /// Puts a picked disk image into the machine folder. On the same volume APFS clones the file,
    /// so even a 30 GB image arrives at once and takes no extra space.
    func importDisk(from url: URL) {
        guard !importing else { return }
        let ext = url.pathExtension.lowercased()
        let name = ext == "hvsparse" ? "windows11.hvsparse" : "windows11.img"
        let folder = URL(fileURLWithPath: machineFolder, isDirectory: true)
        let dest = folder.appendingPathComponent(name)
        let temp = folder.appendingPathComponent(name + ".importing")
        importing = true
        importProgress = 0
        importError = nil

        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            var failure: String?
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try? fm.removeItem(at: temp)
                try fm.copyItem(at: url, to: temp)
                for old in ["windows11.img", "windows11.hvsparse"] {
                    try? fm.removeItem(at: folder.appendingPathComponent(old))
                }
                try fm.moveItem(at: temp, to: dest)
            } catch {
                try? fm.removeItem(at: temp)
                failure = error.localizedDescription
            }
            let result = failure
            await MainActor.run {
                self.importing = false
                self.importError = result
                self.sync()
            }
        }
    }

    // MARK: Sync

    private func sync() {
        jitLive = bridge.isJITLive
        jitStatus = bridge.jitStatusText
        hasFirmware = bridge.hasFirmware
        bundledFirmware = bridge.usesBundledFirmware
        hasDisk = bridge.hasDiskImage
        diskDescription = describeDisk()
        unpackProgress = bridge.unpackProgress

        if bridge.isVMRunning {
            everRan = true
            phase = .running
            let w = bridge.framebufferWidth, h = bridge.framebufferHeight
            let size = CGSize(width: Int(w), height: Int(h))
            if size != guestSize { guestSize = size }
        } else if bridge.isUnpacking {
            phase = .unpacking
        } else if bridge.isStarting {
            phase = .starting
        } else if everRan {
            phase = .stopped(bridge.vmStatusText)
            guestSize = .zero
        } else if phase != .waitingForJIT {
            phase = .idle
        }
        let text = bridge.vmStatusText
        status = text == "Idle" ? "" : text
    }

    private func everySecond() {
        guard phase == .running else { return }
        let frames = bridge.presentedFrames
        fps = Int(frames >= lastFrames ? frames - lastFrames : 0)
        lastFrames = frames
        idlePercent = bridge.guestIdlePercent
        let w = bridge.framebufferWidth, h = bridge.framebufferHeight
        let size = CGSize(width: Int(w), height: Int(h))
        if size != guestSize { guestSize = size }
    }

    private func everyQuarterSecond() {
        if phase == .waitingForJIT, wantsStart {
            if !bridge.isJITLive, bridge.isDebuggerAttached { _ = bridge.tryAcquireJIT(true) }
            if bridge.isJITLive { start() }
        }
        guard phase == .running else { return }
        if bridge.takeGuestOAuthDone() { guestLink = nil }
        if let text = bridge.takeGuestOpenURL(), let url = URL(string: text),
           url.scheme == "http" || url.scheme == "https" {
            guestLink = GuestLink(url: url)
        }
    }

    private func describeDisk() -> String {
        let folder = machineFolder as NSString
        for name in ["windows11.img", "windows11.hvsparse"] {
            let path = folder.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else { continue }
            let text = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
            return name.hasSuffix("hvsparse") ? "\(text), packed" : text
        }
        return ""
    }
}
