//
// TJ fork: Duo fold proxy driver, simulator + Debug only (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Prep notes: WatchLab/Element/research/duo/06_prep_on_26.md §3 (driver D3) and A4.
// Driven from the Mac with WatchLab/Element/tools/duo26.sh, which posts Darwin notifications into the sim:
//   xcrun simctl spawn <udid> notifyutil -p com.turnertomlinson.element.duo.<command>
// A Duo fold is a size-class change on the same scene, so overriding the main window's horizontal size
// class runs the same stack <-> split code path (NavigationCoordinators.swift:344).
// Never compiled into a device or Release build.
//

#if IS_MAIN_APP && DEBUG && targetEnvironment(simulator)

import SwiftUI

final class ForkDuoSimDriver {
    static let shared = ForkDuoSimDriver()

    nonisolated static let prefix = "com.turnertomlinson.element.duo."

    enum Command: String, CaseIterable {
        /// Override the main window's horizontal size class (D3).
        case compact, regular, clear
        /// Same, but on the root view controller (fallback if SwiftUI ignores the window override).
        case compactRoot, regularRoot, clearRoot
        /// `requestGeometryUpdate` on the main scene (D2).
        case landscape, portrait
        /// Probe emits one `ev=dump` line.
        case dump
        /// Focuses the first editable text view in the main window and inserts a fixed, non-secret marker.
        case draft
        /// Ends editing (keyboard down) without touching the text.
        case endEditing
        /// Activates the first accessibility element whose label contains the text in `<app tmp>/duo_arg.txt`
        /// (e.g. a room cell). Mock fixtures only (`UI_TESTS_SCREEN`), so a real session's names are never read.
        case activate
    }

    static let draftMarker = "duo draft T2"

    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in Command.allCases {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let raw = name?.rawValue as String?, raw.hasPrefix(ForkDuoSimDriver.prefix) else { return }
                let value = String(raw.dropFirst(ForkDuoSimDriver.prefix.count))
                Task { @MainActor in
                    ForkDuoSimDriver.shared.handle(value)
                }
            }, (Self.prefix + command.rawValue) as CFString, nil, .deliverImmediately)
        }
        ForkDuoProbe.logger.notice("DUO v=1 ev=driver-ready commands=\(Command.allCases.map(\.rawValue).joined(separator: ","), privacy: .public)")
    }

    func handle(_ raw: String) {
        guard let command = Command(rawValue: raw) else { return }
        ForkDuoProbe.logger.notice("DUO v=1 ev=driver cmd=\(raw, privacy: .public)")
        guard let scene = ForkDuoProbe.findMainScene(), let window = ForkDuoProbe.findMainWindow(in: scene, excluding: nil) else {
            ForkDuoProbe.logger.error("DUO v=1 ev=driver-error cmd=\(raw, privacy: .public) reason=no-main-window")
            return
        }

        switch command {
        case .compact:
            window.traitOverrides.horizontalSizeClass = .compact
        case .regular:
            window.traitOverrides.horizontalSizeClass = .regular
        case .clear:
            window.traitOverrides.remove(UITraitHorizontalSizeClass.self)
        case .compactRoot:
            window.rootViewController?.traitOverrides.horizontalSizeClass = .compact
        case .regularRoot:
            window.rootViewController?.traitOverrides.horizontalSizeClass = .regular
        case .clearRoot:
            window.rootViewController?.traitOverrides.remove(UITraitHorizontalSizeClass.self)
        case .landscape, .portrait:
            let mask: UIInterfaceOrientationMask = command == .landscape ? .landscapeRight : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                let reason = (error as NSError).localizedDescription
                Task { @MainActor in
                    ForkDuoProbe.logger.error("DUO v=1 ev=driver-error cmd=\(raw, privacy: .public) reason=\(reason, privacy: .public)")
                }
            }
        case .dump:
            ForkDuoProbe.shared.emitNow("dump")
        case .draft:
            insertDraft(in: window)
        case .endEditing:
            window.endEditing(true)
        case .activate:
            activate(in: window)
        }
    }
    
    private func activate(in window: UIWindow) {
        guard ProcessInfo.processInfo.environment["UI_TESTS_SCREEN"] != nil else {
            ForkDuoProbe.logger.error("DUO v=1 ev=driver-error cmd=activate reason=mock-fixtures-only")
            return
        }
        let argURL = FileManager.default.temporaryDirectory.appending(path: "duo_arg.txt")
        guard let label = (try? String(contentsOf: argURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            ForkDuoProbe.logger.error("DUO v=1 ev=driver-error cmd=activate reason=no-arg")
            return
        }
        guard let element = Self.accessibilityElement(containing: label, in: window, depth: 0) else {
            ForkDuoProbe.logger.error("DUO v=1 ev=driver-error cmd=activate reason=not-found")
            return
        }
        let frame = element.accessibilityFrame
        let activated = element.accessibilityActivate()
        ForkDuoProbe.logger.notice("DUO v=1 ev=driver-activate matched=1 activated=\(activated ? 1 : 0, privacy: .public) frame=\(Int(frame.minX), privacy: .public),\(Int(frame.minY), privacy: .public),\(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public)")
    }
    
    private static func accessibilityElement(containing label: String, in object: NSObject, depth: Int) -> NSObject? {
        guard depth < 80 else { return nil }
        if object.isAccessibilityElement, object.accessibilityLabel?.localizedCaseInsensitiveContains(label) == true {
            return object
        }
        var children: [NSObject] = []
        if let elements = object.accessibilityElements as? [NSObject] {
            children = elements
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if let view = object as? UIView {
            children += view.subviews.filter { subview in !children.contains { $0 === subview } }
        }
        for child in children {
            if let found = accessibilityElement(containing: label, in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func insertDraft(in window: UIWindow) {
        guard let textView = Self.firstEditableTextView(in: window) else {
            ForkDuoProbe.logger.error("DUO v=1 ev=driver-error cmd=draft reason=no-text-view")
            return
        }
        textView.becomeFirstResponder()
        textView.insertText(Self.draftMarker)
        ForkDuoProbe.logger.notice("DUO v=1 ev=driver-draft inserted=1 len=\(textView.text.count, privacy: .public)")
    }

    private static func firstEditableTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isEditable, textView.window != nil, !textView.isHidden {
            return textView
        }
        for subview in view.subviews {
            if let found = firstEditableTextView(in: subview) {
                return found
            }
        }
        return nil
    }
}

#endif
