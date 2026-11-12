// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The screen before Windows starts: what is in place, what is missing, and Start.
struct HomeView: View {
    @ObservedObject var vm: VMController
    @ObservedObject var settings: AppSettings

    @State private var showSettings = false
    @State private var showImporter = false
    @State private var showGuide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                checklist
                startArea
                footnote
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showSettings) { SettingsView(vm: vm, settings: settings) }
        .sheet(isPresented: $showGuide) { GuideView() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { vm.importDisk(from: url) }
        }
        .alert("Could not import", isPresented: Binding(get: { vm.importError != nil }, set: { if !$0 { vm.importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.importError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Caterpillar")
                    .font(.system(size: 32, weight: .semibold))
                Text("Windows 11 on ARM, on this device")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), interactive: true)
            .accessibilityLabel("Settings")
        }
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            row(title: "Disk image",
                detail: vm.importing ? "Importing…" : vm.hasDisk ? vm.diskDescription : "Not added yet",
                state: vm.hasDisk ? .good : .needed) {
                Button(vm.hasDisk ? "Replace" : "Import") { showImporter = true }
                    .disabled(vm.importing)
            }
            divider
            row(title: "Firmware",
                detail: vm.hasFirmware ? (vm.bundledFirmware ? "Built in" : "Your code.fd") : "Missing",
                state: vm.hasFirmware ? .good : .needed) { EmptyView() }
            divider
            row(title: "JIT",
                detail: vm.jitLive ? "On" : vm.isSimulator ? "Simulator" : "Off — asked for when you start",
                state: vm.jitLive ? .good : .pending) {
                if !vm.jitLive, !vm.isSimulator {
                    Button("Enable") { vm.requestJIT() }
                }
            }
            divider
            row(title: "Display",
                detail: vm.plan.map { "\($0.label) · \(settings.resolution.title)" } ?? "—",
                state: .info) {
                Button("Change") { showSettings = true }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 44)
    }

    private enum RowState { case good, needed, pending, info }

    private func row<Trailing: View>(title: String, detail: String, state: RowState,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state == .good ? "checkmark.circle.fill" : state == .needed ? "circle.dashed" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(state == .good ? Palette.accent : Color.white.opacity(state == .needed ? 0.7 : 0.3))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 8)
            trailing()
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var startArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch vm.phase {
            case .waitingForJIT:
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for JIT").font(.body.weight(.medium))
                        Text("StikDebug should open, attach, and bring you back here.")
                            .font(.footnote).foregroundStyle(Palette.secondaryText)
                    }
                    Spacer()
                    Button("Cancel") { vm.cancelWaiting() }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                }
                .padding(14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            case .unpacking:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unpacking the disk image").font(.body.weight(.medium))
                    ProgressView(value: vm.unpackProgress)
                    Text("\(Int(vm.unpackProgress * 100))% — this happens once.")
                        .font(.footnote).foregroundStyle(Palette.secondaryText)
                }
                .padding(14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            default:
                Button { vm.start() } label: {
                    Text("Start Windows")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(.black)
                .disabled(!vm.canStart)
            }

            if let notice = vm.notice {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            } else if !vm.status.isEmpty, vm.phase == .idle {
                Text(vm.status).font(.footnote).foregroundStyle(Palette.secondaryText)
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !vm.hasDisk {
                Text("Caterpillar does not come with Windows. Bring a Windows 11 ARM64 disk image you made yourself: import it here, or copy it to Files › Caterpillar › Machines › Win11 as windows11.img.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
            Button("How to make a disk image") { showGuide = true }
                .font(.footnote.weight(.medium))
        }
    }
}

/// Short, offline instructions. The long version lives in the repository's README.
struct GuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(String, String)] = [
        ("Get Windows 11 for ARM64",
         "Download the ARM64 installer from Microsoft on a Mac or PC. Use your own licence."),
        ("Build the disk image on a computer",
         "The repository's scripts/provision_windows_arm64.py installs Windows into a raw disk image, windows11.img, with the network driver added. scripts/optimize_windows_lite.py is optional and trims background services so Windows idles with less memory."),
        ("Pack it (optional)",
         "build/hvsparse pack windows11.img windows11.hvsparse skips the empty space, so the transfer is much smaller. Caterpillar unpacks it on first start."),
        ("Copy it to this device",
         "AirDrop it, or connect a cable and drop it into Files › Caterpillar. Then tap Import, or put it in Machines › Win11 yourself."),
        ("Enable JIT and start",
         "Caterpillar needs JIT. Install StikDebug, pair it once, and Caterpillar will ask it for JIT whenever you tap Start."),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(step.0)").font(.body.weight(.medium))
                        Text(step.1).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Disk image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
