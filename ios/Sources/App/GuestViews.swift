// SPDX-License-Identifier: GPL-2.0-or-later
import GameController
import SwiftUI
import UIKit

/// A hardware keyboard, read through GameController so that it reaches Windows whatever has
/// focus in the app. `GCKeyCode` is the USB HID usage, which is what the guest's keyboard speaks.
final class HardwareKeyboard {
    static let shared = HardwareKeyboard()
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.attach()
        }
        attach()
    }

    private func attach() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { _, _, keyCode, pressed in
            let code = keyCode.rawValue
            guard code >= 0x04, code <= 0xe7 else { return }
            GuestKeyboard.shared.raw(UInt8(code), down: pressed)
        }
    }
}

/// The layer Windows is drawn into.
final class MetalCanvasView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        WinIOSBridge.shared.bindMetalLayer(window == nil ? nil : layer as? CAMetalLayer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metal = layer as? CAMetalLayer else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metal.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size.width >= 4, size.height >= 4, metal.drawableSize != size {
            metal.drawableSize = size
        }
    }
}

/// The guest's screen: picture below, touch surface on top.
final class GuestScreenView: UIView {
    let canvas = MetalCanvasView()
    let touch = TouchSurface()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        addSubview(canvas)
        addSubview(touch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        touch.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { HardwareKeyboard.shared.start() }
    }
}

struct GuestScreen: UIViewRepresentable {
    @ObservedObject var settings: AppSettings
    let guestSize: CGSize
    let desktopRect: CGRect
    let onThreeFingerTap: () -> Void

    func makeUIView(context: Context) -> GuestScreenView {
        GuestScreenView()
    }

    func updateUIView(_ view: GuestScreenView, context: Context) {
        let t = view.touch
        t.mode = settings.touchMode
        t.pointerSpeed = settings.pointerSpeed
        t.naturalScroll = settings.naturalScroll
        t.haptics = settings.haptics
        if guestSize.width > 0 {
            t.guestWidth = Double(guestSize.width)
            t.guestHeight = Double(guestSize.height)
        }
        t.onThreeFingerTap = onThreeFingerTap
        t.desktopRect = desktopRect
    }
}

/// A plain trackpad area, used under the screen in portrait.
struct TrackpadPad: UIViewRepresentable {
    @ObservedObject var settings: AppSettings
    let guestSize: CGSize
    let onThreeFingerTap: () -> Void

    func makeUIView(context: Context) -> TouchSurface {
        let t = TouchSurface()
        t.mode = .trackpad
        return t
    }

    func updateUIView(_ t: TouchSurface, context: Context) {
        t.pointerSpeed = settings.pointerSpeed
        t.naturalScroll = settings.naturalScroll
        t.haptics = settings.haptics
        if guestSize.width > 0 {
            t.guestWidth = Double(guestSize.width)
            t.guestHeight = Double(guestSize.height)
        }
        t.onThreeFingerTap = onThreeFingerTap
    }
}

// MARK: - Software keyboard

/// Invisible text target that brings up the iOS keyboard and turns what is typed into key presses.
final class KeyInputView: UIView, UIKeyInput, UITextInputTraits {
    var onDismiss: (() -> Void)?
    let keyBar = KeyBar()

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { keyBar }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        GuestKeyboard.shared.type(text)
    }

    func deleteBackward() {
        GuestKeyboard.shared.tap(HID.backspace)
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let was = isFirstResponder
        let ok = super.resignFirstResponder()
        if was, ok { onDismiss?() }
        return ok
    }

    // A hardware keyboard while the software one is up: HardwareKeyboard already sends the real
    // keys, so swallow the presses here or each one would also arrive as typed text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key == nil }) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key == nil }) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key == nil }) { super.pressesCancelled(presses, with: event) }
    }
}

struct KeyboardHost: UIViewRepresentable {
    @Binding var isShown: Bool
    @Binding var showsTop: Bool
    let canFlip: Bool

    func makeUIView(context: Context) -> KeyInputView {
        let v = KeyInputView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.alpha = 0.01
        return v
    }

    func updateUIView(_ v: KeyInputView, context: Context) {
        v.onDismiss = { if isShown { isShown = false } }
        v.keyBar.onHide = { isShown = false }
        v.keyBar.onFlip = { showsTop.toggle() }
        v.keyBar.setFlipVisible(canFlip)
        if isShown, !v.isFirstResponder {
            DispatchQueue.main.async { if v.window != nil { v.becomeFirstResponder() } }
        } else if !isShown, v.isFirstResponder {
            DispatchQueue.main.async { v.resignFirstResponder() }
        }
    }
}

/// The row above the iOS keyboard with the keys it lacks.
final class KeyBar: UIInputView {
    var onHide: (() -> Void)?
    var onFlip: (() -> Void)?

    private let stack = UIStackView()
    private var modifierButtons: [UInt8: UIButton] = [:]
    private var flipButton: UIButton?

    private struct Key {
        let title: String
        let symbol: String?
        let usage: UInt8
        let sticky: Bool
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        autoresizingMask = .flexibleWidth

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addSubview(scroll)

        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        var keys: [Key] = [
            Key(title: "Esc", symbol: nil, usage: HID.escape, sticky: false),
            Key(title: "Tab", symbol: nil, usage: HID.tab, sticky: false),
            Key(title: "Ctrl", symbol: nil, usage: HID.ctrl, sticky: true),
            Key(title: "Alt", symbol: nil, usage: HID.alt, sticky: true),
            Key(title: "Win", symbol: nil, usage: HID.win, sticky: true),
            Key(title: "Shift", symbol: nil, usage: HID.shift, sticky: true),
            Key(title: "Left", symbol: "arrow.left", usage: HID.left, sticky: false),
            Key(title: "Down", symbol: "arrow.down", usage: HID.down, sticky: false),
            Key(title: "Up", symbol: "arrow.up", usage: HID.up, sticky: false),
            Key(title: "Right", symbol: "arrow.right", usage: HID.right, sticky: false),
            Key(title: "Del", symbol: nil, usage: HID.delete, sticky: false),
            Key(title: "Home", symbol: nil, usage: HID.home, sticky: false),
            Key(title: "End", symbol: nil, usage: HID.end, sticky: false),
            Key(title: "PgUp", symbol: nil, usage: HID.pageUp, sticky: false),
            Key(title: "PgDn", symbol: nil, usage: HID.pageDown, sticky: false),
        ]
        for n in 1...12 {
            keys.append(Key(title: "F\(n)", symbol: nil, usage: HID.f1 + UInt8(n - 1), sticky: false))
        }

        let hide = makeButton(title: "Hide keyboard", symbol: "keyboard.chevron.compact.down")
        hide.addAction(UIAction { [weak self] _ in self?.onHide?() }, for: .touchUpInside)
        stack.addArrangedSubview(hide)

        let flip = makeButton(title: "Show other half of the screen", symbol: "arrow.up.arrow.down")
        flip.addAction(UIAction { [weak self] _ in self?.onFlip?() }, for: .touchUpInside)
        stack.addArrangedSubview(flip)
        flipButton = flip

        for key in keys {
            let b = makeButton(title: key.title, symbol: key.symbol)
            if key.sticky {
                modifierButtons[key.usage] = b
                b.addAction(UIAction { _ in GuestKeyboard.shared.toggleArmed(key.usage) }, for: .touchUpInside)
            } else {
                b.addAction(UIAction { _ in GuestKeyboard.shared.tap(key.usage) }, for: .touchUpInside)
            }
            stack.addArrangedSubview(b)
        }

        GuestKeyboard.shared.onArmedChanged = { [weak self] in self?.refreshModifiers() }
        refreshModifiers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setFlipVisible(_ visible: Bool) {
        flipButton?.isHidden = !visible
    }

    private func makeButton(title: String, symbol: String?) -> UIButton {
        var cfg = UIButton.Configuration.gray()
        cfg.cornerStyle = .medium
        cfg.baseForegroundColor = .label
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11)
        if let symbol {
            cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        } else {
            var text = AttributedString(title)
            text.font = .systemFont(ofSize: 14, weight: .medium)
            cfg.attributedTitle = text
        }
        let b = UIButton(configuration: cfg)
        b.accessibilityLabel = title
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.setContentHuggingPriority(.required, for: .horizontal)
        if symbol != nil { b.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }

    private func refreshModifiers() {
        let armed = GuestKeyboard.shared.armed
        for (usage, button) in modifierButtons {
            guard var cfg = button.configuration else { continue }
            let on = armed.contains(usage)
            cfg.baseBackgroundColor = on ? .label : nil
            cfg.baseForegroundColor = on ? .systemBackground : .label
            button.configuration = cfg
        }
    }
}
