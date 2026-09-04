// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreGraphics

enum SwitcherAppIconCache {
    private static let lock = NSLock()
    private static var icons: [pid_t: NSImage] = [:]
    private static var generation: UInt64 = 0

    static func beginSession(items: [SwitcherItem], appearance: NSAppearance) -> UInt64 {
        let pids = Set(items.map(\.pid))
        let resolved = Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            stableBundleIcon(pid: pid, appearance: appearance).map { (pid, $0) }
        })
        return lock.withLock {
            generation &+= 1
            icons = resolved
            return generation
        }
    }

    static func icon(for pid: pid_t) -> NSImage? {
        if let cached = lock.withLock({ icons[pid] }) { return cached }
        guard let resolved = stableBundleIcon(pid: pid,
                                              appearance: NSApplication.shared.effectiveAppearance)
        else { return nil }
        lock.withLock { icons[pid] = resolved }
        return resolved
    }

    static func refreshDockPluginIcons(items: [SwitcherItem],
                                       darkMode: Bool,
                                       generation expectedGeneration: UInt64,
                                       onUpdate: @escaping (pid_t) -> Void) {
        let targets = items.reduce(into: [pid_t: URL]()) { result, item in
            guard result[item.pid] == nil else { return }
            guard let app = NSRunningApplication(processIdentifier: item.pid),
                  let bundleURL = app.bundleURL,
                  let bundle = Bundle(url: bundleURL),
                  let pluginName = bundle.object(forInfoDictionaryKey: "NSDockTilePlugIn") as? String
            else { return }
            let pluginURL = bundleURL.appendingPathComponent("Contents/PlugIns")
                .appendingPathComponent(pluginName)
            guard FileManager.default.fileExists(atPath: pluginURL.path) else { return }
            result[item.pid] = pluginURL
        }
        guard !targets.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            for (pid, pluginURL) in targets {
                guard let image = dockPluginIcon(pluginURL: pluginURL, darkMode: darkMode) else { continue }
                let stored = lock.withLock { () -> Bool in
                    guard generation == expectedGeneration else { return false }
                    icons[pid] = image
                    return true
                }
                guard stored else { return }
                DispatchQueue.main.async { onUpdate(pid) }
            }
        }
    }

    static func declaredDockIconURL(bundleURL: URL,
                                    resourceName: String?,
                                    darkMode: Bool) -> URL? {
        guard let resourceName = resourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resourceName.isEmpty,
              !resourceName.hasPrefix("/") else { return nil }
        let replacements: [(String, String)] = darkMode
            ? [("-light.", "-dark-color."), ("-light.", "-dark.")]
            : [("-dark-color.", "-light."), ("-dark.", "-light.")]
        let names = replacements.compactMap { source, destination in
            resourceName.contains(source)
                ? resourceName.replacingOccurrences(of: source, with: destination)
                : nil
        } + [resourceName]

        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        for name in names {
            let candidate = resources.appendingPathComponent(name)
                .resolvingSymlinksInPath().standardizedFileURL
            guard candidate.path.hasPrefix(resources.path + "/") else { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func stableBundleIcon(pid: pid_t, appearance: NSAppearance) -> NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let declaredIcon = app.bundleURL.flatMap { bundleURL -> NSImage? in
            guard let bundleIdentifier = app.bundleIdentifier,
                  let resourceName = CFPreferencesCopyAppValue(
                      "DockIconResourceName" as CFString,
                      bundleIdentifier as CFString
                  ) as? String,
                  let resourceURL = declaredDockIconURL(bundleURL: bundleURL,
                                                        resourceName: resourceName,
                                                        darkMode: darkMode)
            else { return nil }
            return NSImage(contentsOf: resourceURL)
        }
        let source = declaredIcon
            ?? app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? app.icon
        guard let source else { return nil }
        return NSImage(size: source.size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance { source.draw(in: rect) }
            return true
        }
    }

    private static func dockPluginIcon(pluginURL: URL, darkMode: Bool) -> NSImage? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DockIconResolver")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-dock-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = helper
        process.arguments = [pluginURL.path, darkMode ? "dark" : "light", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        if finished.wait(timeout: .now() + 1) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        guard let data = try? Data(contentsOf: output) else { return nil }
        return NSImage(data: data)
    }
}

enum WindowSwitchMinimizedPlacement: String, CaseIterable {
    case normal
    case end
    case hidden
}

/// One selectable entry in the switcher. Most entries are real user-facing
/// windows; Finder can also appear as an app entry when it has no windows, so
/// the user can still switch to the desktop/menu bar like the system switcher.
struct SwitcherItem: Identifiable, Equatable {
    let id: String
    let title: String
    let appName: String
    /// The regular app represented by this entry. App grouping, icons, MRU,
    /// activation and quit actions use this process.
    let pid: pid_t
    /// The process that actually owns `windowID`. Multi-process apps can render
    /// their user-facing windows in an embedded accessory helper.
    let windowOwnerPID: pid_t
    /// The backing CGWindow: thumbnails and AX raising go through it.
    let windowID: CGWindowID?
    let isOnScreen: Bool
    let isAppHidden: Bool
    let isMinimized: Bool
    let isFullscreen: Bool
    /// The window belongs only to Spaces that are not currently visible.
    let isOnHiddenSpace: Bool
    /// Window-server coordinates, top-left origin: `kCGWindowBounds`, or the
    /// Accessibility position and size when the window server has no usable
    /// bounds. Never an AppKit (bottom-left) frame, so it can be compared with
    /// `CGDisplayBounds` directly. `.zero` for an entry without a window.
    let frame: CGRect

    /// The window whose thumbnail represents this entry.
    var previewWindowID: CGWindowID? { windowID }

    /// Label shown under the thumbnail; untitled windows fall back to the app name.
    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    func windowLabel(noOpenWindow: String) -> String {
        isAppEntry ? noOpenWindow : displayTitle
    }

    /// The line under an app's name, when there is one worth reading. A window
    /// titled after its own app would only repeat the line above it, which is
    /// the same rule `displaySubtitle` already applies the other way round.
    func windowDetail(noOpenWindow: String) -> String? {
        if isAppEntry { return noOpenWindow }
        return displaySubtitle == nil ? nil : displayTitle
    }

    /// Secondary label used when the window title does not already identify the
    /// app. This keeps crowded switcher grids readable without repeating text.
    var displaySubtitle: String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAppName.isEmpty,
              !cleanTitle.isEmpty,
              cleanTitle.caseInsensitiveCompare(cleanAppName) != .orderedSame
        else { return nil }
        return cleanAppName
    }

    var accessibilityTitle: String {
        if let displaySubtitle {
            return "\(displayTitle), \(displaySubtitle)"
        }
        return displayTitle
    }

    /// Whether this entry stands for the app itself because it has no window
    /// to switch to. Those entries have no thumbnail to draw and no window to
    /// name, so several places have to present them differently.
    var isAppEntry: Bool { windowID == nil }

    /// What the screen reader hears. An app entry replaces the window title
    /// with its state on screen, so the label has to carry that state too or
    /// the entry sounds identical to a window of the same app.
    ///
    /// Lives on the model rather than beside one view: the Dock preview card
    /// draws the same badges and owes its reader the same sentence.
    func spokenLabel(noOpenWindow: String,
                     hiddenApp: String,
                     otherDesktop: String) -> String {
        var label = isAppEntry ? "\(appName), \(noOpenWindow)" : accessibilityTitle
        if isAppHidden { label += ", \(hiddenApp)" }
        if isOnHiddenSpace { label += ", \(otherDesktop)" }
        return label
    }

    /// Read from the bundle on disk, the same icon Finder and the Dock draw,
    /// so an app whose user picked one of its alternate icons shows the one
    /// they picked. Asking the running process instead hands back one cached
    /// NSImage for the app's whole life, and a view that already drew it never
    /// redraws it, so the switcher stayed on the bundled icon (issue #801).
    var appIcon: NSImage? {
        SwitcherAppIconCache.icon(for: pid)
    }

    func withMinimized(_ minimized: Bool) -> SwitcherItem {
        SwitcherItem(id: id,
                     title: title,
                     appName: appName,
                     pid: pid,
                     windowOwnerPID: windowOwnerPID,
                     windowID: windowID,
                     isOnScreen: minimized ? false : true,
                     isAppHidden: isAppHidden,
                     isMinimized: minimized,
                     isFullscreen: isFullscreen,
                     isOnHiddenSpace: isOnHiddenSpace,
                     frame: frame)
    }

    func withHiddenSpaceState(_ hidden: Bool) -> SwitcherItem {
        SwitcherItem(id: id,
                     title: title,
                     appName: appName,
                     pid: pid,
                     windowOwnerPID: windowOwnerPID,
                     windowID: windowID,
                     isOnScreen: isOnScreen,
                     isAppHidden: isAppHidden,
                     isMinimized: isMinimized,
                     isFullscreen: isFullscreen,
                     isOnHiddenSpace: hidden,
                     frame: frame)
    }

    static func window(id: CGWindowID, title: String, appName: String, pid: pid_t,
                       windowOwnerPID: pid_t? = nil,
                       isOnScreen: Bool, isAppHidden: Bool = false,
                       isMinimized: Bool = false,
                       isFullscreen: Bool = false, frame: CGRect) -> SwitcherItem {
        SwitcherItem(id: "w:\(id)", title: title, appName: appName,
                     pid: pid, windowOwnerPID: windowOwnerPID ?? pid,
                     windowID: id, isOnScreen: isOnScreen,
                     isAppHidden: isAppHidden,
                     isMinimized: isMinimized, isFullscreen: isFullscreen,
                     isOnHiddenSpace: false,
                     frame: frame)
    }

    static func appOnly(appName: String, pid: pid_t,
                        isAppHidden: Bool = false) -> SwitcherItem {
        SwitcherItem(id: "a:\(pid)", title: appName, appName: appName,
                     pid: pid, windowOwnerPID: pid, windowID: nil, isOnScreen: false,
                     isAppHidden: isAppHidden,
                     isMinimized: false, isFullscreen: false,
                     isOnHiddenSpace: false, frame: .zero)
    }
}
