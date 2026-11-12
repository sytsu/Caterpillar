// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

/// Turns fingers (and a hardware mouse) into guest pointer input.
///
/// Touch mode: the pointer goes where the finger is. Tap clicks, drag drags, hold right-clicks.
/// Trackpad mode: the finger moves the pointer the way a laptop trackpad does. Tap clicks,
/// hold or double-tap-and-drag grabs.
/// Both: two fingers scroll, a two-finger tap right-clicks, a three-finger tap calls `onThreeFingerTap`.
final class TouchSurface: UIView {
    var mode: TouchMode = .direct
    var pointerSpeed: Double = 1.0
    var naturalScroll = true
    var haptics = true
    /// Guest framebuffer width in pixels: sets how far the pointer travels per point of finger travel.
    var guestWidth: Double = 1344
    var guestHeight: Double = 720
    var onThreeFingerTap: (() -> Void)?

    private let pointer = GuestPointer.shared
    private var active: [UITouch] = []
    private var maxFingers = 0
    private var startPoint = CGPoint.zero
    private var startTime: TimeInterval = 0
    private var lastPoint = CGPoint.zero
    private var lastMoveTime: TimeInterval = 0
    private var moved = false
    private var dragging = false
    private var holdFired = false
    private var holdTimer: Timer?
    private var scrollAnchor = CGPoint.zero
    private var scrollCarry: CGFloat = 0
    private var scrolled = false
    private var lastTapTime: TimeInterval = 0
    private var mouseButtons: UInt8 = 0

    private static let slop: CGFloat = 8
    private static let holdDelay: TimeInterval = 0.42
    private static let scrollStep: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)

        let wheel = UIPanGestureRecognizer(target: self, action: #selector(onWheel(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        addGestureRecognizer(wheel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Hardware mouse

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        moveAbsolute(to: g.location(in: self))
    }

    @objc private func onWheel(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        emitScroll(t.y, natural: false)
    }

    private func mouseMask(_ event: UIEvent?) -> UInt8 {
        var mask: UInt8 = 0
        let b = event?.buttonMask ?? .primary
        if b.contains(.primary) || b.isEmpty { mask |= GuestPointer.left }
        if b.contains(.secondary) { mask |= GuestPointer.right }
        return mask
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first, t.type == .indirectPointer {
            moveAbsolute(to: t.location(in: self))
            mouseButtons = mouseMask(event)
            pointer.set(mouseButtons, down: true)
            return
        }

        for t in touches where !active.contains(t) { active.append(t) }
        maxFingers = max(maxFingers, active.count)

        if active.count == 1, let t = active.first {
            let p = t.location(in: self)
            startPoint = p
            lastPoint = p
            startTime = t.timestamp
            lastMoveTime = t.timestamp
            moved = false
            dragging = false
            holdFired = false
            scrolled = false
            if mode == .direct { moveAbsolute(to: p) }
            // Trackpad: a second tap that stays down grabs, like tap-and-a-half on a laptop.
            if mode == .trackpad, t.timestamp - lastTapTime < 0.30 {
                beginDrag()
            } else {
                armHold()
            }
        } else if active.count == 2 {
            cancelHold()
            if dragging { endDrag() }
            scrollAnchor = centroid()
            scrollCarry = 0
        } else {
            cancelHold()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first, t.type == .indirectPointer {
            moveAbsolute(to: t.location(in: self))
            return
        }

        if active.count == 1, maxFingers == 1, let t = active.first {
            let p = t.location(in: self)
            if !moved, hypot(p.x - startPoint.x, p.y - startPoint.y) > Self.slop {
                moved = true
                cancelHold()
                if mode == .direct, !holdFired {
                    // Press where the finger first landed, so a window is grabbed by its title bar
                    // rather than a few points away from it.
                    moveAbsolute(to: startPoint)
                    beginDrag()
                }
            }
            if moved || dragging {
                if mode == .direct {
                    moveAbsolute(to: p)
                } else {
                    moveRelative(from: lastPoint, to: p, dt: t.timestamp - lastMoveTime)
                }
            }
            lastPoint = p
            lastMoveTime = t.timestamp
        } else if active.count == 2 {
            let c = centroid()
            let dy = c.y - scrollAnchor.y
            scrollAnchor = c
            if abs(dy) > 0 { emitScroll(dy, natural: naturalScroll) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first, t.type == .indirectPointer {
            pointer.set(mouseButtons, down: false)
            mouseButtons = 0
            return
        }
        let endTime = touches.first?.timestamp ?? startTime
        active.removeAll { touches.contains($0) }
        guard active.isEmpty else { return }

        cancelHold()
        let quick = endTime - startTime < 0.35
        if dragging {
            endDrag()
        } else if maxFingers == 1, !moved, !holdFired {
            pointer.click(GuestPointer.left)
            lastTapTime = endTime
        } else if maxFingers == 2, !scrolled, quick {
            pointer.click(GuestPointer.right)
            tick()
        } else if maxFingers == 3, quick {
            onThreeFingerTap?()
        }
        maxFingers = 0
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.removeAll()
        maxFingers = 0
        cancelHold()
        dragging = false
        mouseButtons = 0
        pointer.releaseAll()
    }

    // MARK: Pieces

    private func moveAbsolute(to p: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        pointer.move(toX: Double(p.x / bounds.width), y: Double(p.y / bounds.height))
    }

    private func moveRelative(from a: CGPoint, to b: CGPoint, dt: TimeInterval) {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        // Slow movement is precise, fast movement crosses the screen: gain grows with finger speed.
        let speed = dt > 0 ? hypot(dx, dy) / dt : 0
        let gain = pointerSpeed * (1.3 + min(speed / 500, 2.2))
        pointer.move(byX: dx * gain / guestWidth, y: dy * gain / guestHeight)
    }

    private func emitScroll(_ dy: CGFloat, natural: Bool) {
        scrollCarry += dy
        let notches = Int(scrollCarry / Self.scrollStep)
        guard notches != 0 else { return }
        scrollCarry -= CGFloat(notches) * Self.scrollStep
        scrolled = true
        // A finger moving down drags the content down, which is the wheel turning up.
        pointer.scroll(natural ? notches : -notches)
    }

    private func centroid() -> CGPoint {
        guard !active.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for t in active {
            let p = t.location(in: self)
            x += p.x
            y += p.y
        }
        return CGPoint(x: x / CGFloat(active.count), y: y / CGFloat(active.count))
    }

    private func beginDrag() {
        dragging = true
        pointer.set(GuestPointer.left, down: true)
    }

    private func endDrag() {
        dragging = false
        pointer.set(GuestPointer.left, down: false)
    }

    private func armHold() {
        cancelHold()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            guard let self, self.active.count == 1, !self.moved, !self.dragging else { return }
            self.holdFired = true
            self.tick()
            if self.mode == .direct {
                self.pointer.click(GuestPointer.right)
            } else {
                self.beginDrag()
            }
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func tick() {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
