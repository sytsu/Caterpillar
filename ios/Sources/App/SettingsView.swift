// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: VMController
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var running: Bool { vm.phase == .running }

    var body: some View {
        NavigationStack {
            Form {
                display
                machine
                input
                general
                about
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var display: some View {
        Section {
            Picker("Resolution", selection: $settings.resolution) {
                ForEach(ResolutionPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Picker("Picture", selection: $settings.fit) {
                ForEach(DisplayFit.allCases) { fit in
                    Text(fit.title).tag(fit)
                }
            }
            if let plan = vm.plan {
                LabeledContent("Windows will use", value: plan.label)
            }
            Picker("Orientation", selection: $settings.orientation) {
                ForEach(OrientationLock.allCases) { lock in
                    Text(lock.title).tag(lock)
                }
            }
            Toggle("Crisp pixels", isOn: $settings.sharpPixels)
            Toggle("Limit to 30 frames a second", isOn: $settings.limitTo30)
            Toggle("Show frame rate", isOn: $settings.showStats)
        } header: {
            Text("Display")
        } footer: {
            Text(running
                 ? "Resolution and picture shape are fixed while Windows runs. Changes apply the next time it starts."
                 : "Windows draws everything on the processor, so fewer pixels is faster. Fast suits most things; raise the scale in Windows display settings if text looks small.")
        }
    }

    private var machine: some View {
        Section {
            Picker("Memory", selection: $settings.ramMB) {
                Text("Automatic").tag(0)
                Text("2 GB").tag(2048)
                Text("3 GB").tag(3072)
                Text("4 GB").tag(4096)
                Text("4.5 GB").tag(4608)
            }
            Picker("Processor cores", selection: $settings.cores) {
                Text("2").tag(2)
                Text("4").tag(4)
                Text("6").tag(6)
            }
            if running {
                LabeledContent("Running with", value: "\(vm.configuredRamMB) MB, \(vm.configuredCores) cores")
            }
        } header: {
            Text("Machine")
        } footer: {
            Text("Automatic gives Windows as much memory as the device can spare. Applies the next time Windows starts.")
        }
    }

    private var input: some View {
        Section("Input") {
            Picker("Screen works as", selection: $settings.touchMode) {
                ForEach(TouchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Trackpad speed")
                Slider(value: $settings.pointerSpeed, in: 0.5...2.0)
            }
            Toggle("Natural scrolling", isOn: $settings.naturalScroll)
            Toggle("Haptics", isOn: $settings.haptics)
        }
    }

    private var general: some View {
        Section {
            Toggle("Start Windows when the app opens", isOn: $settings.autoStart)
            Toggle("Open links from Windows in Safari", isOn: $settings.guestLinksInSafari)
            Toggle("Write diagnostics to Files", isOn: $settings.diagnostics)
        } header: {
            Text("General")
        } footer: {
            Text("The Shared folder in Files › Caterpillar is reachable from Windows at http://10.0.2.4/. Diagnostics keeps boot_status.txt and a screenshot of the first minutes in the Caterpillar folder.")
        }
    }

    private var about: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            LabeledContent("JIT", value: vm.jitStatus)
            NavigationLink("Licences") { LicencesView() }
        } header: {
            Text("About")
        } footer: {
            Text("Caterpillar is free software under the GNU GPL, version 2 or later. It is a fork of WindowsiOS by Ammaar Reshi. Windows is a trademark of Microsoft; Caterpillar is not affiliated with or endorsed by Microsoft.")
        }
    }
}

struct LicencesView: View {
    private var text: String {
        var parts: [String] = []
        for name in ["THIRD_PARTY_NOTICES", "edk2-licenses"] {
            for ext in ["md", "txt"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext),
                   let body = try? String(contentsOf: url, encoding: .utf8) {
                    parts.append(body)
                }
            }
        }
        return parts.isEmpty ? "See THIRD_PARTY_NOTICES.md in the source repository." : parts.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}
