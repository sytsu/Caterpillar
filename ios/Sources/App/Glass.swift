// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

enum Palette {
    static let background = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let card = Color(red: 0.086, green: 0.086, blue: 0.094)
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(red: 0.66, green: 0.82, blue: 0.55)
    static let secondaryText = Color.white.opacity(0.56)
}

extension View {
    /// Liquid Glass where the system has it (iOS 26 and later), a thin material before that.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.plainGlass(in: shape)
        }
        #else
        self.plainGlass(in: shape)
        #endif
    }

    private func plainGlass<S: Shape>(in shape: S) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// A round control that floats beside or over the Windows picture.
struct GlassButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(active ? Palette.accent : Color.white)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle(), interactive: true)
        .accessibilityLabel(label)
    }
}
