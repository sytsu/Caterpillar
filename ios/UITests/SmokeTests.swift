// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

/// Drives the app in the Simulator, where the whole machine runs. With an empty disk image the
/// firmware ends in the UEFI shell, which is enough to check the picture, the keyboard and the
/// layout; with a Windows image the pointer tests apply too.
///
///     scripts/ui_test.sh            # screenshots land in build/ui-shots
final class SmokeTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        addUIInterruptionMonitor(withDescription: "Permission") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["CATERPILLAR_SHOTS"] {
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A fresh Simulator shows a "slide to type" tip over the keyboard the first time it appears.
    private func dismissKeyboardTip() {
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 3) { tip.tap() }
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
    }

    func testHome() {
        launch(["-general.autoStart", "NO", "-display.orientation", "portrait"])
        XCTAssertTrue(app.buttons["Start Windows"].waitForExistence(timeout: 60))
        shot("home-portrait")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        shot("home-settings")
    }

    func testLandscapeSession() {
        launch(["-general.autoStart", "YES", "-display.orientation", "landscape", "-display.showStats", "YES"])
        let keyboard = app.buttons["Keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 90), "session did not appear")
        sleep(14) // firmware start, then the shell's five-second countdown
        shot("landscape-session")

        keyboard.tap()
        XCTAssertTrue(app.buttons["Esc"].waitForExistence(timeout: 10), "key bar did not appear")
        dismissKeyboardTip()
        app.typeText("ver\n")
        sleep(2)
        shot("landscape-keyboard")

        app.buttons["Show other half of the screen"].tap()
        sleep(1)
        shot("landscape-keyboard-top")
        app.typeText("echo Caterpillar 123 !@#\n")
        sleep(2)
        shot("landscape-typed")

        app.buttons["Hide keyboard"].tap()
        sleep(1)
        app.buttons["Menu"].tap()
        sleep(1)
        shot("landscape-menu")
        app.buttons["Save Screenshot"].tap()
        sleep(1)
        shot("landscape-toast")
    }

    func testPortraitSession() {
        launch(["-general.autoStart", "YES", "-display.orientation", "portrait"])
        let keyboard = app.buttons["Keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 90), "session did not appear")
        sleep(14)
        shot("portrait-session")
        keyboard.tap()
        XCTAssertTrue(app.buttons["Esc"].waitForExistence(timeout: 10), "key bar did not appear")
        dismissKeyboardTip()
        app.typeText("ver\n")
        sleep(2)
        shot("portrait-keyboard")
        app.buttons["Hide keyboard"].tap()
        sleep(1)
        shot("portrait-trackpad")
    }

    /// Sends touches to an app that is already running, without relaunching it: for poking at a
    /// booted Windows by hand. See scripts/ui_drive.sh. Coordinates are fractions of the screen.
    ///   tap X Y | hold X Y SECONDS | drag X1 Y1 X2 Y2 | twotap | type TEXT | button LABEL
    ///   sysbutton LABEL | wait SECONDS | shot NAME
    func testDrive() throws {
        guard let script = ProcessInfo.processInfo.environment["CATERPILLAR_ACTIONS"], !script.isEmpty else {
            throw XCTSkip("no CATERPILLAR_ACTIONS given")
        }
        let running = XCUIApplication(bundleIdentifier: "com.sytsu.caterpillar")
        running.activate()
        func at(_ x: String, _ y: String) -> XCUICoordinate {
            running.coordinate(withNormalizedOffset: CGVector(dx: Double(x) ?? 0.5, dy: Double(y) ?? 0.5))
        }
        for line in script.split(separator: ";") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let verb = parts.first else { continue }
            let rest = parts.count > 1 ? parts[1] : ""
            let args = rest.split(separator: " ").map(String.init)
            switch verb {
            case "tap" where args.count >= 2: at(args[0], args[1]).tap()
            case "hold" where args.count >= 3: at(args[0], args[1]).press(forDuration: Double(args[2]) ?? 0.8)
            case "drag" where args.count >= 4:
                at(args[0], args[1]).press(forDuration: 0.15, thenDragTo: at(args[2], args[3]))
            case "twotap": running.twoFingerTap()
            case "sysbutton":
                // A button in a system alert, such as "Allow Paste".
                let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let button = system.buttons[rest].firstMatch
                if button.waitForExistence(timeout: 5) { button.tap() }
            case "type": running.typeText(rest.replacingOccurrences(of: "\\n", with: "\n"))
            case "button": running.buttons[rest].firstMatch.tap()
            case "wait": Thread.sleep(forTimeInterval: Double(rest) ?? 1)
            case "shot": shot(rest)
            default: XCTFail("unknown action: \(line)")
            }
        }
    }
}
