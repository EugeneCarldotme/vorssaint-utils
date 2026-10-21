// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

// Appended beside the production service to exercise its private event routing.
extension QuitProtectionRoutingContract.QuitProtectionService {
    static func routingChecks(_ suite: TestSuite) {
        typealias Contract = QuitProtectionRoutingContract
        let defaults = Contract.UserDefaults.standard
        defaults.removePersistentDomain(forName: "vorss.tests.quit-routing")
        defer { defaults.removePersistentDomain(forName: "vorss.tests.quit-routing") }
        defaults.set(true, forKey: DefaultsKey.quitProtectionQuitEnabled)
        defaults.set("selectedOnly", forKey: DefaultsKey.quitProtectionQuitScope)
        defaults.set(["com.google.Chrome"], forKey: DefaultsKey.quitProtectionQuitExceptions)
        defaults.set(true, forKey: DefaultsKey.quitProtectionQuitShowFeedback)
        defaults.set(true, forKey: DefaultsKey.quitProtectionCloseEnabled)

        let service = Self()
        service.isRunning = true
        service.frontmostProcessIdentifier = 100
        service.frontmostBundleIdentifier = "com.google.Chrome"
        defer { service.stop() }

        @discardableResult
        func send(_ key: CGKeyCode, _ type: CGEventType = .keyDown,
                  flags: CGEventFlags = .maskCommand, repeatKey: Bool = false) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type == .keyDown)!
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            return service.handle(type: type, event: event) != nil
        }

        // Chrome stays frontmost while the native switcher selects another app.
        // A held Q must reach the switcher, with no termination of Chrome.
        for mode in QuitProtectionMode.allCases {
            defaults.set(mode.rawValue, forKey: DefaultsKey.quitProtectionQuitMode)
            Contract.NSRunningApplication.terminated = []
            send(48)
            send(48, .keyUp)
            let passed = send(12)
            let repeated = send(12, repeatKey: true)
            let secondPress = send(12)
            let extraModifier = send(12, flags: [.maskCommand, .maskShift])
            service.holdTimer?.fire()
            let released = send(12, .keyUp)
            suite.expect(passed && repeated && secondPress && extraModifier && released && service.pending == nil
                         && !service.hud.visible && Contract.NSRunningApplication.terminated.isEmpty,
                         "native Command-Tab owns Q in \(mode.rawValue) mode without quitting the foreground app")
            send(55, .flagsChanged, flags: [])
        }

        send(48)
        suite.expect(send(13) && send(13, .keyUp) && service.pending == nil,
                     "native Command-Tab also receives W without starting foreground-window protection")
        send(55, .flagsChanged, flags: [])

        // Protection still works once Command is released.
        defaults.set("hold", forKey: DefaultsKey.quitProtectionQuitMode)
        Contract.NSRunningApplication.terminated = []
        suite.expect(!send(12) && service.pending != nil, "ordinary Command-Q still starts protection")
        service.holdTimer?.fire()
        suite.expect(Contract.NSRunningApplication.terminated == [100],
                     "an ordinary confirmed hold still quits its protected target")
        send(12, .keyUp)

        // A confirmation started before Command-Tab must not survive it.
        Contract.NSRunningApplication.terminated = []
        send(12)
        let oldTimer = service.holdTimer
        send(48, flags: [.maskCommand, .maskShift])
        oldTimer?.fire()
        suite.expect(service.pending == nil && !service.hud.visible
                     && Contract.NSRunningApplication.terminated.isEmpty,
                     "reverse Command-Tab cancels an existing hold before its timer can quit the foreground app")
        send(12, .keyUp)
        send(55, .flagsChanged, flags: [])

        // Escape dismisses the native switcher even while Command stays down.
        send(48)
        suite.expect(send(53) && !send(12) && service.pending != nil,
                     "Escape restores ordinary protection without requiring Command to be released")
        send(12, .keyUp)
        suite.expect(!service.hud.visible, "releasing an unconfirmed hold still hides its HUD")

        // Modified Tab shortcuts that do not open the native switcher must
        // leave ordinary protection available.
        for flags: CGEventFlags in [[.maskCommand, .maskAlternate], [.maskCommand, .maskControl]] {
            send(48, flags: flags)
            suite.expect(!send(12) && service.pending != nil,
                         "a non-switcher modified Tab does not bypass quit protection")
            send(12, .keyUp)
        }

        // A key event without Command also ends the chord if its modifier
        // release event was missed.
        send(48)
        send(48, .keyUp, flags: [])
        suite.expect(!send(12), "a later event with Command released ends native switcher ownership")
        send(12, .keyUp)

        // Custom switcher ownership remains authoritative in either tap order.
        send(48)
        Contract.AppSwitcher.shared.keyboardInputOwnership = (true, 1)
        suite.expect(send(12) && service.pending == nil, "the custom switcher still receives its selection keys")
        Contract.AppSwitcher.shared.keyboardInputOwnership = (false, 1)
        suite.expect(!send(12), "a custom switcher session does not leave stale native ownership")
        send(12, .keyUp)

        send(48)
        service.stop()
        service.isRunning = true
        suite.expect(!send(12), "stopping the service clears native switcher ownership before a restart")
        send(12, .keyUp)
    }
}
