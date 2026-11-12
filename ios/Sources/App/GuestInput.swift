// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

/// USB HID usage codes (keyboard page) used by the on-screen keys.
enum HID {
    static let enter: UInt8 = 0x28, escape: UInt8 = 0x29, backspace: UInt8 = 0x2a, tab: UInt8 = 0x2b, space: UInt8 = 0x2c
    static let f1: UInt8 = 0x3a, printScreen: UInt8 = 0x46
    static let insert: UInt8 = 0x49, home: UInt8 = 0x4a, pageUp: UInt8 = 0x4b, delete: UInt8 = 0x4c
    static let end: UInt8 = 0x4d, pageDown: UInt8 = 0x4e
    static let right: UInt8 = 0x4f, left: UInt8 = 0x50, down: UInt8 = 0x51, up: UInt8 = 0x52
    static let ctrl: UInt8 = 0xe0, shift: UInt8 = 0xe1, alt: UInt8 = 0xe2, win: UInt8 = 0xe3

    /// US layout: the key for a character, and whether Shift is held.
    static func stroke(for ch: Character) -> (usage: UInt8, shift: Bool)? {
        guard let ascii = normalized(ch).asciiValue else { return nil }
        switch ascii {
        case 97...122: return (0x04 + (ascii - 97), false)
        case 65...90: return (0x04 + (ascii - 65), true)
        case 49...57: return (0x1e + (ascii - 49), false)
        case 48: return (0x27, false)
        case 10, 13: return (enter, false)
        case 9: return (tab, false)
        case 32: return (space, false)
        default: break
        }
        if let i = plain.firstIndex(of: ascii) { return (plainUsage[i], false) }
        if let i = shifted.firstIndex(of: ascii) { return (shiftedUsage[i], true) }
        return nil
    }

    private static let plain = Array("-=[]\\;'`,./".utf8)
    private static let plainUsage: [UInt8] = [0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38]
    private static let shifted = Array("!@#$%^&*()_+{}|:\"~<>?".utf8)
    private static let shiftedUsage: [UInt8] = [0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
                                                0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38]

    /// The iOS keyboard likes typographic punctuation; Windows gets the plain key.
    private static func normalized(_ ch: Character) -> Character {
        switch ch {
        case "\u{2018}", "\u{2019}": return "'"
        case "\u{201C}", "\u{201D}": return "\""
        case "\u{2013}", "\u{2014}": return "-"
        case "\u{00A0}": return " "
        default: return ch
        }
    }
}

/// The guest's pointer. Windows sees an absolute USB tablet; relative (trackpad) motion is added up here.
final class GuestPointer {
    static let shared = GuestPointer()

    static let left: UInt8 = 1, right: UInt8 = 2, middle: UInt8 = 4

    private let bridge = WinIOSBridge.shared
    private(set) var x = 0.5
    private(set) var y = 0.5
    private var buttons: UInt8 = 0

    func move(toX nx: Double, y ny: Double) {
        x = min(max(nx, 0), 1)
        y = min(max(ny, 0), 1)
        send(wheel: 0)
    }

    func move(byX dx: Double, y dy: Double) {
        move(toX: x + dx, y: y + dy)
    }

    func set(_ button: UInt8, down: Bool) {
        let next = down ? buttons | button : buttons & ~button
        guard next != buttons else { return }
        buttons = next
        send(wheel: 0)
    }

    func click(_ button: UInt8) {
        set(button, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [self] in
            set(button, down: false)
        }
    }

    func releaseAll() {
        guard buttons != 0 else { return }
        buttons = 0
        send(wheel: 0)
    }

    /// Positive scrolls up, in wheel notches.
    func scroll(_ notches: Int) {
        guard notches != 0 else { return }
        send(wheel: Int8(clamping: notches))
    }

    private func send(wheel: Int8) {
        bridge.sendTabletNormalizedX(x, y: y, buttons: buttons, wheel: wheel)
    }
}

/// The guest's keyboard. Typed text and shortcuts are queued so that key order survives fast input.
final class GuestKeyboard {
    static let shared = GuestKeyboard()

    private let bridge = WinIOSBridge.shared
    private let queue = DispatchQueue(label: "caterpillar.keys", qos: .userInteractive)

    /// Modifiers tapped on the key bar; they apply to the next key, then let go.
    private(set) var armed: Set<UInt8> = []
    var onArmedChanged: (() -> Void)?

    /// A key held on a hardware keyboard: passed straight through.
    func raw(_ usage: UInt8, down: Bool) {
        bridge.sendKeyHid(usage, down: down)
    }

    func toggleArmed(_ modifier: UInt8) {
        if armed.contains(modifier) { armed.remove(modifier) } else { armed.insert(modifier) }
        onArmedChanged?()
    }

    /// Press and release one key, with the armed modifiers and any extra ones.
    func tap(_ usage: UInt8, modifiers: [UInt8] = []) {
        var mods = modifiers
        for m in armed.sorted() where !mods.contains(m) { mods.append(m) }
        if !armed.isEmpty {
            armed.removeAll()
            onArmedChanged?()
        }
        enqueue(usage, mods)
    }

    /// A lone modifier press, such as the Windows key opening Start.
    func tapModifier(_ modifier: UInt8) {
        enqueue(modifier, [])
    }

    func type(_ text: String) {
        for ch in text {
            guard let s = HID.stroke(for: ch) else { continue }
            tap(s.usage, modifiers: s.shift ? [HID.shift] : [])
        }
    }

    private func enqueue(_ usage: UInt8, _ mods: [UInt8]) {
        let bridge = self.bridge
        queue.async {
            for m in mods { bridge.sendKeyHid(m, down: true) }
            if !mods.isEmpty { usleep(12_000) }
            bridge.sendKeyHid(usage, down: true)
            usleep(26_000)
            bridge.sendKeyHid(usage, down: false)
            if !mods.isEmpty { usleep(10_000) }
            for m in mods.reversed() { bridge.sendKeyHid(m, down: false) }
            usleep(12_000)
        }
    }
}
