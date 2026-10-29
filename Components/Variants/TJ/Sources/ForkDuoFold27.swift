//
// TJ fork: Duo fold assist, iOS 27.1 only (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// NOT COMPILED ON XCODE 26.6 (`TJ_SDK27`), and every type is `@available(iOS 27.1, *)`.
// Spec: WatchLab/Element/01_DUO_SPEC.md rev 2 §2-§3 (postures from `UIHinge.Status`), §4.4 (no hinge-driven layout),
// §5.1 (continuity lives in the coordinators), §7 (APIs, all [V-sdk] in iPhoneOS27.1.sdk).
//
// Zero upstream edits. One full-size, non-interactive, accessibility-hidden anchor view sits at the back of the
// upstream main window and carries:
// - a `UIHingeInteraction` (UIHingeInteraction.h:52,63). The hinge is used for interaction state only, never for
//   layout: the SDK says prefer `status` over the angle and don't depend on its rate (UIHinge.h:64-68);
// - trait registration for the horizontal size class and `systemTraitsAffectingVerticalBarEdge` (UIVerticalBarEdge.h:42);
// - `layoutSubviews`, which re-samples reserved regions once layout settles (the first pass is transient, spec §2).
//
// What it does with them:
// 1. Keyboard continuity across a fold: if the composer had focus when the phone folded or unfolded, focus the
//    same composer again once the stack/split swap settles (spec R2 lists "keyboard stays up" as allowed to fail in
//    v2; this recovers it with zero edits). The draft text itself already survives in the coordinators (T2).
// 2. Sheets off the fold: while a `.division` region is active (partially open), a sheet that the system left across
//    an upright fold gets `preferredPlacement = .leading` (UISheetPresentationController.h:120, iOS 27.0), and goes
//    back to `.automatic` when the fold flattens. Apple says the system already keeps sheets and alerts off the
//    division (HIG, [V-doc]); this only acts when a measured sheet frame still crosses it. Alerts have no placement
//    API, so a crossing alert is only logged.
// 3. Feeds the probe (Debug) with hinge status/angle, `verticalBarEdge` and the division/occlusion frames.
//
// Runtime switch: Developer options > "Fold assist" (`tj.duo.foldAssist`, default on). Off = observe and log only.
//

#if IS_MAIN_APP && TJ_SDK27

import os
import SwiftUI

@available(iOS 27.1, *)
struct ForkDuoFoldSnapshot: Equatable {
    /// nil when no hinge provider is in the hierarchy (not a foldable, or the anchor is detached).
    var hingeStatus: UIHinge.Status?
    var hingeAngle: CGFloat = 0
    var barEdge: UIVerticalBarEdge = .unspecified
    var horizontalSizeClass: UIUserInterfaceSizeClass = .unspecified
    /// Window coordinates.
    var activeDivisions: [CGRect] = []
    var inactiveDivisionCount = 0
    var activeOcclusions: [CGRect] = []

    var probeFields: String {
        let hinge = hingeStatus.map { "\(Self.name($0)):\(Int((hingeAngle * 180 / .pi).rounded()))deg" } ?? "nil"
        let division = activeDivisions.isEmpty ? "-" : activeDivisions.map(Self.rect).joined(separator: ";")
        let occlusion = activeOcclusions.isEmpty ? "-" : activeOcclusions.map(Self.rect).joined(separator: ";")
        return "hinge=\(hinge) bar=\(Self.name(barEdge)) div=\(division) divInactive=\(inactiveDivisionCount) occ=\(occlusion)"
    }

    static func name(_ status: UIHinge.Status) -> String {
        switch status {
        case .closed: "closed"
        case .partiallyOpen: "partiallyOpen"
        case .fullyOpen: "fullyOpen"
        default: "unknown"
        }
    }

    static func name(_ edge: UIVerticalBarEdge) -> String {
        switch edge {
        case .leading: "leading"
        case .trailing: "trailing"
        default: "unspecified"
        }
    }

    static func rect(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))"
    }
}

@available(iOS 27.1, *)
final class ForkDuoFoldMonitor {
    static let shared = ForkDuoFoldMonitor()

    nonisolated static let logger = Logger(subsystem: "com.turnertomlinson.element", category: "DuoProbe")

    /// How long after the composer loses focus a fold still counts as "the fold took the keyboard away".
    static let focusGrace: TimeInterval = 1.5
    /// Lets SwiftUI finish the stack <-> split swap before focusing the recreated composer.
    static let restoreDelay: Duration = .milliseconds(600)
    static let sheetGuardInterval: Duration = .milliseconds(300)

    private(set) var snapshot = ForkDuoFoldSnapshot()

    private var isStarted = false
    private weak var window: UIWindow?
    private var anchor: ForkDuoFoldAnchorView?
    private var observers: [NSObjectProtocol] = []

    private var focusedComposer: ComposerIdentity?
    private var focusLost: (composer: ComposerIdentity, at: Date)?
    private var restoreTask: Task<Void, Never>?

    private var sheetGuardTask: Task<Void, Never>?
    private var placedSheets: [WeakSheet] = []

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        observe(center, UIScene.didActivateNotification) { $0.attachIfNeeded() }
        observe(center, UIResponder.keyboardDidShowNotification) { $0.keyboardDidShow() }
        observe(center, UIResponder.keyboardDidHideNotification) { $0.keyboardDidHide() }
        attachIfNeeded()
        Self.logger.notice("DUO v=1 ev=fold-start assist=\(ForkDuoSettings.foldAssistEnabled ? 1 : 0, privacy: .public)")
    }

    // MARK: - Attachment

    private func attachIfNeeded() {
        guard let window = ForkDuoRuntime.mainWindow() else { return }
        guard window !== self.window || anchor?.superview !== window else { return }
        anchor?.removeFromSuperview()
        self.window = window

        let anchor = ForkDuoFoldAnchorView(frame: window.bounds)
        anchor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        anchor.onLayout = { ForkDuoFoldMonitor.shared.sample(reason: "layout") }
        window.insertSubview(anchor, at: 0)

        anchor.addInteraction(UIHingeInteraction { _, update in
            ForkDuoFoldMonitor.shared.hingeChanged(update.hinge)
        })
        let traits: [UITrait] = [UITraitHorizontalSizeClass.self] + UITraitCollection.systemTraitsAffectingVerticalBarEdge
        anchor.registerForTraitChanges(traits) { (view: ForkDuoFoldAnchorView, previous: UITraitCollection) in
            ForkDuoFoldMonitor.shared.traitsChanged(view.traitCollection, previous: previous)
        }
        self.anchor = anchor
        snapshot.horizontalSizeClass = window.traitCollection.horizontalSizeClass
        sample(reason: "attach")
    }

    // MARK: - Inputs

    private func hingeChanged(_ hinge: UIHinge?) {
        let oldStatus = snapshot.hingeStatus
        snapshot.hingeStatus = hinge?.status
        snapshot.hingeAngle = hinge?.angle ?? 0
        guard oldStatus != snapshot.hingeStatus else { return } // angle-only updates: not used (no hinge-driven layout)

        Self.logger.notice("DUO v=1 ev=fold-hinge from=\(oldStatus.map(ForkDuoFoldSnapshot.name) ?? "nil", privacy: .public) to=\(self.snapshot.hingeStatus.map(ForkDuoFoldSnapshot.name) ?? "nil", privacy: .public)")
        if oldStatus != nil, Self.isFoldTransition(from: oldStatus, to: snapshot.hingeStatus) {
            foldTransitionStarted(reason: "hinge")
        }
        updateSheetGuard()
        sample(reason: "hinge")
        notifyProbe("hinge")
    }

    private func traitsChanged(_ traits: UITraitCollection, previous: UITraitCollection) {
        let oldEdge = snapshot.barEdge
        snapshot.barEdge = traits.verticalBarEdge
        if traits.horizontalSizeClass != previous.horizontalSizeClass {
            snapshot.horizontalSizeClass = traits.horizontalSizeClass
            // The Duo fold is a size-class change on the same scene (spec §2); this is the stack <-> split swap.
            foldTransitionStarted(reason: "size-class")
        }
        if oldEdge != snapshot.barEdge {
            Self.logger.notice("DUO v=1 ev=fold-bar edge=\(ForkDuoFoldSnapshot.name(self.snapshot.barEdge), privacy: .public)")
        }
        notifyProbe("trait")
    }

    private func sample(reason: String) {
        guard let window else { return }
        let divisions = window.reservedRegions(kind: .division, options: .includeInactive)
        let occlusions = window.reservedRegions(kind: .occlusion)
        var next = snapshot
        next.barEdge = window.traitCollection.verticalBarEdge
        next.activeDivisions = divisions.filter(\.isActive).map(\.frame)
        next.inactiveDivisionCount = divisions.count(where: { !$0.isActive })
        next.activeOcclusions = occlusions.filter(\.isActive).map(\.frame)
        guard next != snapshot else { return }
        let divisionChanged = next.activeDivisions != snapshot.activeDivisions
        snapshot = next
        if divisionChanged {
            Self.logger.notice("DUO v=1 ev=fold-division reason=\(reason, privacy: .public) \(self.snapshot.probeFields, privacy: .public)")
            updateSheetGuard()
        }
        notifyProbe("regions")
    }

    private func notifyProbe(_ event: String) {
        #if TJ_DUO_PROBE
        ForkDuoProbe.shared.scheduleEmit(event)
        #endif
    }

    // MARK: - Keyboard continuity

    private struct ComposerIdentity: Equatable {
        let accessibilityIdentifier: String?
        let typeName: String
    }

    private func keyboardDidShow() {
        guard let window, let textView = Self.firstResponderTextView(in: window) else {
            focusedComposer = nil
            return
        }
        focusedComposer = ComposerIdentity(accessibilityIdentifier: textView.accessibilityIdentifier, typeName: String(describing: type(of: textView)))
        focusLost = nil
    }

    private func keyboardDidHide() {
        if let focusedComposer {
            focusLost = (focusedComposer, .now)
        }
        focusedComposer = nil
    }

    private func foldTransitionStarted(reason: String) {
        let composer: ComposerIdentity? = if let focusedComposer {
            focusedComposer
        } else if let focusLost, Date.now.timeIntervalSince(focusLost.at) < Self.focusGrace {
            focusLost.composer
        } else {
            nil
        }
        Self.logger.notice("DUO v=1 ev=fold-transition reason=\(reason, privacy: .public) composerFocused=\(composer == nil ? 0 : 1, privacy: .public)")
        guard let composer, ForkDuoSettings.foldAssistEnabled else { return }

        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: Self.restoreDelay)
            guard !Task.isCancelled else { return }
            self?.restoreFocus(composer)
        }
    }

    private func restoreFocus(_ composer: ComposerIdentity) {
        guard let window,
              window.windowScene?.activationState == .foregroundActive,
              !ForkDuoRuntime.isLockWindowVisible,
              Self.firstResponderTextView(in: window) == nil else {
            Self.logger.notice("DUO v=1 ev=fold-keyboard restored=0 reason=state")
            return
        }
        guard let textView = Self.textView(matching: composer, in: window) else {
            Self.logger.notice("DUO v=1 ev=fold-keyboard restored=0 reason=no-composer")
            return
        }
        let restored = textView.becomeFirstResponder()
        focusLost = nil
        Self.logger.notice("DUO v=1 ev=fold-keyboard restored=\(restored ? 1 : 0, privacy: .public)")
    }

    private static func isFoldTransition(from old: UIHinge.Status?, to new: UIHinge.Status?) -> Bool {
        (old == .closed) != (new == .closed)
    }

    private static func firstResponderTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isFirstResponder {
            return textView
        }
        for subview in view.subviews {
            if let found = firstResponderTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func textView(matching composer: ComposerIdentity, in view: UIView) -> UITextView? {
        if let textView = view as? UITextView,
           textView.isEditable, !textView.isHidden, textView.window != nil,
           textView.accessibilityIdentifier == composer.accessibilityIdentifier,
           String(describing: type(of: textView)) == composer.typeName {
            return textView
        }
        for subview in view.subviews {
            if let found = textView(matching: composer, in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Sheets off the fold

    private struct WeakSheet {
        weak var sheet: UISheetPresentationController?
    }

    private func updateSheetGuard() {
        let shouldRun = ForkDuoSettings.foldAssistEnabled && (snapshot.hingeStatus == .partiallyOpen || !snapshot.activeDivisions.isEmpty)
        if shouldRun, sheetGuardTask == nil {
            sheetGuardTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.guardSheets()
                    try? await Task.sleep(for: Self.sheetGuardInterval)
                }
            }
        } else if !shouldRun, let task = sheetGuardTask {
            task.cancel()
            sheetGuardTask = nil
            releaseSheets()
        }
    }

    private func guardSheets() {
        guard let window else { return }
        sample(reason: "guard")
        // Only an upright fold (a tall, thin division, book posture) can be avoided by leading/trailing placement.
        let uprightDivisions = snapshot.activeDivisions.filter { $0.height > $0.width }
        guard !uprightDivisions.isEmpty else {
            releaseSheets()
            return
        }

        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController {
            defer { presenter = presented }
            guard let presentedView = presented.viewIfLoaded, presentedView.window === window else { continue }
            let frame = presentedView.convert(presentedView.bounds, to: window)
            guard uprightDivisions.contains(where: { $0.intersects(frame) && frame.width < window.bounds.width }) else { continue }

            if presented is UIAlertController {
                Self.logger.notice("DUO v=1 ev=fold-alert crossesDivision=1")
            } else if let sheet = presented.sheetPresentationController, sheet.sourceView == nil, sheet.preferredPlacement == .automatic {
                sheet.animateChanges { sheet.preferredPlacement = .leading }
                placedSheets.append(WeakSheet(sheet: sheet))
                Self.logger.notice("DUO v=1 ev=fold-sheet placement=leading")
            }
        }
    }

    private func releaseSheets() {
        for entry in placedSheets {
            guard let sheet = entry.sheet, sheet.preferredPlacement == .leading else { continue }
            sheet.animateChanges { sheet.preferredPlacement = .automatic }
            Self.logger.notice("DUO v=1 ev=fold-sheet placement=automatic")
        }
        placedSheets.removeAll()
    }

    // MARK: - Helpers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (ForkDuoFoldMonitor) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                handler(ForkDuoFoldMonitor.shared)
            }
        })
    }
}

/// Full-size, transparent, non-interactive and accessibility-hidden: it never takes a touch or a VoiceOver stop.
@available(iOS 27.1, *)
final class ForkDuoFoldAnchorView: UIView {
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

#endif
