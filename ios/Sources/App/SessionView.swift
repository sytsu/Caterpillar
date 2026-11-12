// SPDX-License-Identifier: GPL-2.0-or-later
import SafariServices
import SwiftUI
import UIKit

/// Windows on screen.
///
/// Landscape: the picture fills the screen (or the part of it clear of the camera and rounded
/// corners), and the controls sit in the margin beside it, so nothing covers Windows.
/// Portrait: the picture is on top, with the controls, a trackpad and the keyboard below it.
struct SessionView: View {
    @ObservedObject var vm: VMController
    @ObservedObject var settings: AppSettings

    @State private var keyboardShown = false
    @State private var showsTop = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var cameraOnLeft = true
    @State private var showSettings = false
    @State private var confirmShutDown = false
    @State private var confirmStop = false
    @State private var toast: String?

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            ZStack(alignment: .topLeading) {
                Color.black
                if full.width > full.height {
                    landscape(full: full, insets: insets)
                } else {
                    portrait(full: full, insets: insets)
                }
                KeyboardHost(isShown: $keyboardShown, showsTop: $showsTop, canFlip: full.width > full.height)
                    .frame(width: 1, height: 1)
                overlays(full: full)
            }
            .frame(width: full.width, height: full.height, alignment: .topLeading)
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .statusBarHidden(true)
        .onAppear {
            vm.applyDisplayOptions()
            readOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { readOrientation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let height = max(0, UIScreen.main.bounds.height - end.minY)
            withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
        }
        .onChange(of: settings.limitTo30) { _, _ in vm.applyDisplayOptions() }
        .onChange(of: settings.sharpPixels) { _, _ in vm.applyDisplayOptions() }
        .sheet(isPresented: $showSettings) { SettingsView(vm: vm, settings: settings) }
        .sheet(item: $vm.guestLink) { link in SafariSheet(url: link.url).ignoresSafeArea() }
        .confirmationDialog("Shut down Windows?", isPresented: $confirmShutDown, titleVisibility: .visible) {
            Button("Shut Down") { vm.shutDown() }
        } message: {
            Text("This presses the power button. Windows closes your apps and turns off.")
        }
        .confirmationDialog("Force Windows to stop?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) { vm.forceStop() }
        } message: {
            Text("Like pulling the plug: unsaved work in Windows is lost.")
        }
    }

    // MARK: Layout

    private var aspect: CGFloat {
        if vm.guestSize.width > 0, vm.guestSize.height > 0 { return vm.guestSize.width / vm.guestSize.height }
        return vm.plan?.aspect ?? 16.0 / 9.0
    }

    private func fitted(in area: CGRect) -> CGRect {
        var size = CGSize(width: area.width, height: area.width / aspect)
        if size.height > area.height {
            size = CGSize(width: area.height * aspect, height: area.height)
        }
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    @ViewBuilder
    private func landscape(full: CGSize, insets: EdgeInsets) -> some View {
        let side = max(insets.leading, insets.trailing)
        let keepClear = settings.fit == .safe && side >= 44
        let area = keepClear ? CGRect(x: side, y: 0, width: full.width - 2 * side, height: full.height)
                             : CGRect(origin: .zero, size: full)
        let frame = fitted(in: area)
        let visibleHeight = full.height - keyboardHeight
        let lift = (keyboardHeight > 0 && !showsTop) ? max(0, frame.maxY - visibleHeight) : 0
        // Controls go in the margin away from the camera; without a margin they float over the edge.
        let margin = max(frame.minX, 0)
        let columnWidth: CGFloat = 44
        let columnX = margin >= columnWidth
            ? (cameraOnLeft ? full.width - margin / 2 : margin / 2)
            : (cameraOnLeft ? full.width - columnWidth / 2 - 10 : columnWidth / 2 + 10)

        screen
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY - lift)

        controls(vertical: true)
            .opacity(margin >= columnWidth ? 1 : 0.7)
            .frame(width: columnWidth, height: full.height - keyboardHeight)
            .offset(x: columnX - columnWidth / 2, y: 0)
    }

    @ViewBuilder
    private func portrait(full: CGSize, insets: EdgeInsets) -> some View {
        let top = insets.top
        let frame = CGRect(x: 0, y: top, width: full.width, height: full.width / aspect)
        let barHeight: CGFloat = 60
        let bottom = keyboardHeight > 0 ? full.height - keyboardHeight : full.height - max(insets.bottom, 12)
        let padTop = frame.maxY + barHeight
        let padHeight = max(0, bottom - padTop - 8)

        screen
            .frame(width: frame.width, height: frame.height)
            .offset(x: 0, y: frame.minY)

        controls(vertical: false)
            .frame(width: full.width, height: barHeight)
            .offset(x: 0, y: frame.maxY)

        if padHeight > 60 {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Palette.card)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
                Text("Trackpad")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.18))
                TrackpadPad(settings: settings, guestSize: vm.guestSize) { keyboardShown.toggle() }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .frame(width: full.width - 24, height: padHeight)
            .offset(x: 12, y: padTop)
        }
    }

    private var screen: some View {
        GuestScreen(settings: settings, guestSize: vm.guestSize, keyboardShown: keyboardShown) {
            keyboardShown.toggle()
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            menu
            GlassButton(symbol: "keyboard", label: "Keyboard", active: keyboardShown) {
                keyboardShown.toggle()
            }
            GlassButton(symbol: settings.touchMode.symbol,
                        label: settings.touchMode == .direct ? "Switch to trackpad" : "Switch to touch") {
                settings.touchMode = settings.touchMode == .direct ? .trackpad : .direct
                show(settings.touchMode == .direct ? "Touch" : "Trackpad")
            }
            GlassButton(symbol: "square.grid.2x2", label: "Windows key") {
                GuestKeyboard.shared.tapModifier(HID.win)
            }
            if settings.showStats || vm.thermalLimited {
                VStack(spacing: 1) {
                    if vm.thermalLimited {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Slowed to cool down")
                    }
                    if settings.showStats {
                        Text("\(vm.fps)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        Text("fps")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 40)
            }
        }
    }

    private var menu: some View {
        Menu {
            Section {
                Button("Ctrl + Alt + Del") { WinIOSBridge.shared.sendCtrlAltDel() }
                Button("Task Manager") { GuestKeyboard.shared.tap(HID.escape, modifiers: [HID.ctrl, HID.shift]) }
                Button("Switch App") { GuestKeyboard.shared.tap(HID.tab, modifiers: [HID.alt]) }
                Button("Close Window") { GuestKeyboard.shared.tap(HID.f1 + 3, modifiers: [HID.alt]) }
                Button("Escape") { GuestKeyboard.shared.tap(HID.escape) }
            }
            Section {
                Button {
                    if let text = UIPasteboard.general.string, !text.isEmpty {
                        GuestKeyboard.shared.type(text)
                    } else {
                        show("Clipboard has no text")
                    }
                } label: { Label("Type Clipboard", systemImage: "doc.on.clipboard") }
                Button {
                    show(vm.saveScreenshot() ? "Saved to Files › Caterpillar › Screenshots" : "Could not save")
                } label: { Label("Save Screenshot", systemImage: "camera") }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            Section {
                Button { confirmShutDown = true } label: { Label("Shut Down…", systemImage: "power") }
                Button(role: .destructive) { confirmStop = true } label: { Label("Force Stop…", systemImage: "xmark.octagon") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .glass(in: Circle(), interactive: true)
        .accessibilityLabel("Menu")
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlays(full: CGSize) -> some View {
        if vm.phase == .running, vm.guestSize.width == 0 {
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting").font(.footnote).foregroundStyle(Palette.secondaryText)
            }
            .frame(width: full.width, height: full.height)
            .allowsHitTesting(false)
        }

        if case .stopped(let reason) = vm.phase {
            VStack(spacing: 14) {
                Text("Windows has stopped").font(.headline)
                Text("\(reason)\nTo start it again, close Caterpillar and open it.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.secondaryText)
                Button("Close Caterpillar") {
                    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(.black)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .frame(width: full.width, height: full.height)
        }

        if let toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glass(in: Capsule())
                .frame(width: full.width)
                .offset(y: 16)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func show(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == text { withAnimation(.easeIn(duration: 0.25)) { toast = nil } }
        }
    }

    private func readOrientation() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        // landscapeRight: the top of the device, and with it the camera, is on the left.
        cameraOnLeft = scene?.interfaceOrientation != .landscapeLeft
    }
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
