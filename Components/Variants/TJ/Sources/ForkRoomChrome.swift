//
// TJ fork: room chrome — rail items, Artifacts zone placement, TJ sheets (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, D1–D3, D9, §5.1–§5.3, §5.4a, §5.6, §5.7.
// The ONE upstream hook (RoomFlowCoordinator.swift presentRoom, 2 lines) wraps each presented RoomScreenCoordinator in
// `ForkRoomChrome.wrap(...)`. Under unit tests `wrap` returns the inner coordinator unchanged (D2), so upstream's
// `rootCoordinator is RoomScreenCoordinator` assertions keep holding with no test edit.
//

import OSLog
import SwiftUI

enum ForkRoomChrome {
    static func wrap(_ coordinator: any CoordinatorProtocol,
                     roomProxy: JoinedRoomProxyProtocol,
                     stack: NavigationStackCoordinator,
                     flowParameters: CommonFlowParameters,
                     flow: RoomFlowCoordinator?) -> any CoordinatorProtocol {
        if ProcessInfo.isRunningUnitTests { return coordinator }
        let userID = flowParameters.userSession.clientProxy.userID
        let model = ForkArtifactsStore.shared.model(roomID: roomProxy.id, userID: userID)
        return ForkRoomChromeCoordinator(inner: coordinator, model: model, roomProxy: roomProxy, stack: stack, flowParameters: flowParameters, flow: flow)
    }
}

/// Observable posture inputs the wrapper view reports (window width, size class, scene, vertical bar).
@Observable
final class ForkRoomChromeState {
    var sizeClass: UserInterfaceSizeClass?
    var windowWidth: CGFloat = 0
    var detailWidth: CGFloat = 0
    /// Set one layout pass after `.detailOnly`, so the pane is laid out against the settled detail width.
    var paneReady = false
    /// iOS 27.1 `toolbarVerticalEdge` (nil = horizontal bar); always nil before 27.1.
    var hasVerticalBar = false
    @ObservationIgnored weak var windowScene: UIWindowScene?
}

final class ForkRoomChromeCoordinator: CoordinatorProtocol {
    let inner: any CoordinatorProtocol
    let model: ForkArtifactsModel
    let state = ForkRoomChromeState()
    private let roomProxy: JoinedRoomProxyProtocol?
    private weak var stack: NavigationStackCoordinator?
    private let flowParameters: CommonFlowParameters?
    private weak var flow: RoomFlowCoordinator?
    private let overlay = ForkArtifactOverlayController()
    private var startChat: ForkStartChatPresenter?
    private weak var pushedZone: ForkArtifactsCoordinator?
    private var isRepositioning = false
    private var sheetClosedByAction = false
    private(set) lazy var innerPresentable: AnyView = inner.toPresentable()

    init(inner: any CoordinatorProtocol,
         model: ForkArtifactsModel,
         roomProxy: JoinedRoomProxyProtocol? = nil,
         stack: NavigationStackCoordinator? = nil,
         flowParameters: CommonFlowParameters? = nil,
         flow: RoomFlowCoordinator? = nil) {
        self.inner = inner
        self.model = model
        self.roomProxy = roomProxy
        self.stack = stack
        self.flowParameters = flowParameters
        self.flow = flow
        if let flowParameters, let stack {
            startChat = ForkStartChatPresenter(flowParameters: flowParameters, stack: stack, flow: flow)
        }
        model.onModeChange = { value in ForkRoomChromeCoordinator.reportProbe(value) }
    }

    /// Test seam (ForkRoomChromeTests): direct construction, no room, no network.
    convenience init(inner: any CoordinatorProtocol) {
        let rest = ForkMatrixREST(userID: "@test:localhost") { _ in nil }
        self.init(inner: inner, model: ForkArtifactsModel(userID: "@test:localhost", roomID: "!test:localhost", rest: rest,
                                                           cacheBase: FileManager.default.temporaryDirectory.appending(path: "TJArtifactsTests")))
    }

    // MARK: CoordinatorProtocol

    func start() {
        inner.start()
        if roomProxy != nil { model.roomOpened() }
    }

    func stop() {
        inner.stop()
        if model.isFullScreen { exitFullScreen() }
        if model.layoutMode == .split { leaveSplit() }
        model.isOpen = false
        model.setLayoutMode(.chatOnly)
    }

    func toPresentable() -> AnyView {
        AnyView(ForkRoomChromeView(coordinator: self, model: model, state: state))
    }

    // MARK: Posture

    var split: NavigationSplitCoordinator? {
        stack?.navigationSplitCoordinator
    }

    /// Read inside the view body so the split's (observable) column visibility is tracked.
    var splitColumnVisibility: NavigationSplitViewVisibility? {
        split?.columnVisibility
    }

    var isEncrypted: Bool {
        roomProxy?.infoPublisher.value.isEncrypted ?? false
    }

    func windowChanged(size: CGSize, scene: UIWindowScene?) {
        state.windowScene = scene
        guard abs(size.width - state.windowWidth) > 0.5 else { return }
        state.windowWidth = size.width
        reevaluate()
    }

    func sizeClassChanged(_ sizeClass: UserInterfaceSizeClass?) {
        guard state.sizeClass != sizeClass else { return }
        state.sizeClass = sizeClass
        reevaluate()
    }

    func viewAppeared(sizeClass: UserInterfaceSizeClass?) {
        state.sizeClass = sizeClass
        reevaluate()
    }

    func columnVisibilityChanged(_ visibility: NavigationSplitViewVisibility?) {
        #if DEBUG
        Logger(subsystem: "tj.artifacts", category: "chrome").notice("TJCHROME visibility=\(String(describing: visibility), privacy: .public) mode=\(String(describing: self.model.layoutMode), privacy: .public) repositioning=\(self.isRepositioning, privacy: .public)")
        #endif
        // §5.3: the user re-showing the sidebar while split closes the zone (selection, views, timer stay in the model).
        guard !isRepositioning, model.layoutMode == .split, let visibility, visibility != .detailOnly else { return }
        model.savedColumnVisibility = nil
        model.isOpen = false
        transition(to: .chatOnly)
    }

    func reevaluate() {
        let target = ForkArtifactLayout.mode(sizeClass: state.sizeClass, windowWidth: state.windowWidth, hasSplit: split != nil,
                                             isOpen: model.isOpen, isFullScreen: false)
        transition(to: target)
    }

    private func transition(to target: ForkArtifactLayout.Mode) {
        let current = model.layoutMode
        #if DEBUG
        if target != current {
            Logger(subsystem: "tj.artifacts", category: "chrome").notice("TJCHROME transition \(String(describing: current), privacy: .public) -> \(String(describing: target), privacy: .public) window=\(self.state.windowWidth, privacy: .public) size=\(String(describing: self.state.sizeClass), privacy: .public)")
        }
        #endif
        guard target != current else { return }
        isRepositioning = true
        defer { isRepositioning = false }

        switch current {
        case .push: popZone()
        case .split: leaveSplit()
        case .chatOnly, .full: break
        }
        model.setLayoutMode(target == .full ? .push : target)
        switch target {
        case .push: pushZone()
        case .split: enterSplit()
        case .chatOnly, .full: break
        }
    }

    private func pushZone() {
        guard let stack else { return }
        let zone = ForkArtifactsCoordinator(model: model, actions: zoneActions)
        pushedZone = zone
        stack.push(zone, animated: !isRepositioningForFold) { [weak self] in
            guard let self, !isRepositioning, model.layoutMode == .push else { return }
            // The system Back: back to chat.
            model.isOpen = false
            model.setLayoutMode(.chatOnly)
        }
    }

    /// A fold/rotation repositions without animation; a tap animates.
    private var isRepositioningForFold = false

    private func popZone() {
        guard let stack, let pushedZone else { return }
        if stack.stackCoordinators.contains(where: { $0 === pushedZone }) {
            stack.pop(to: self, animated: false)
            if stack.stackCoordinators.contains(where: { $0 === pushedZone }) {
                // The wrapper isn't on this stack's path (unexpected): pop the zone itself.
                stack.pop(animated: false)
            }
        }
        self.pushedZone = nil
    }

    private func enterSplit() {
        guard let split else { return }
        model.savedColumnVisibility = split.columnVisibility
        state.paneReady = false
        split.columnVisibility = .detailOnly
        Task { [weak self] in
            // Wait one layout pass so the detail width has settled before the pane appears.
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, model.layoutMode == .split else { return }
            state.paneReady = true
        }
    }

    private func leaveSplit() {
        state.paneReady = false
        if let split, split.columnVisibility == .detailOnly, let saved = model.savedColumnVisibility {
            split.columnVisibility = saved
        }
        model.savedColumnVisibility = nil
    }

    // MARK: Actions

    var zoneActions: ForkArtifactsActions {
        ForkArtifactsActions(backToChat: { [weak self] in self?.closeArtifacts() },
                             newArtifact: { [weak self] in self?.presentNewArtifact() },
                             requestChange: { [weak self] entry in self?.presentChange(for: entry) },
                             enterFullScreen: { [weak self] in self?.enterFullScreen() },
                             addToHomeScreen: { [weak self] entry in self?.presentAddToHomeScreen(entry) })
    }

    /// §13.3: the icon maker + install paths, as a sheet on the split (like New artifact).
    func presentAddToHomeScreen(_ entry: ForkArtifactEntry) {
        guard let stack, let link = ForkArtifactDeepLink(roomID: model.roomID, aid: entry.aid) else { return }
        if model.isFullScreen { exitFullScreen() }
        let draft = ForkHomeScreenDraft(link: link, entry: entry)
        let sheet = ForkHomeScreenSheet(draft: draft) { [weak self] in self?.stack?.setSheetCoordinator(nil) }
        stack.setSheetCoordinator(ForkHostingCoordinator(sheet))
    }

    func toggleArtifacts() {
        model.isOpen ? closeArtifacts() : openArtifacts()
    }

    func openArtifacts() {
        model.isOpen = true
        if model.selectedAID == nil { model.selectedAID = model.entries.first?.aid }
        reevaluate()
        Task { await model.refresh() }
    }

    func closeArtifacts() {
        if model.isFullScreen { exitFullScreen() }
        model.isOpen = false
        reevaluate()
    }

    func enterFullScreen() {
        guard let scene = state.windowScene, model.selectedEntry != nil else { return }
        model.setFullScreen(true)
        overlay.present(model: model, on: scene) { [weak self] in self?.exitFullScreen() }
    }

    func exitFullScreen() {
        overlay.dismiss()
        model.setFullScreen(false)
        reevaluate()
    }

    func presentStartChat() {
        startChat?.present()
    }

    func presentNewArtifact() {
        model.beginNewArtifact()
        presentDraftSheet()
    }

    func presentChange(for entry: ForkArtifactEntry) {
        guard entry.pipe == .nas, entry.isHTML else { return }
        model.beginChange(for: entry)
        presentDraftSheet()
    }

    private func presentDraftSheet() {
        guard let stack else { return }
        sheetClosedByAction = false
        let sheet = ForkNewArtifactSheet(model: model,
                                         isEncrypted: isEncrypted,
                                         onCancel: { [weak self] in
                                             guard let self else { return }
                                             sheetClosedByAction = true
                                             model.clearDraft()
                                             self.stack?.setSheetCoordinator(nil)
                                         },
                                         onSend: { [weak self] in await self?.sendDraft() })
        stack.setSheetCoordinator(ForkHostingCoordinator(sheet)) { [weak self] in
            guard let self, !sheetClosedByAction else { return }
            // Dismissed without Notify or Cancel (swipe, or a fold rebuilding the hierarchy): keep the draft (§5.3).
            model.draftKept = !model.draft.isEmpty
        }
    }

    private func sendDraft() async {
        let roomProxy = roomProxy
        let ok = await model.sendDraft(isEncrypted: isEncrypted) { body in
            guard let roomProxy else { return false }
            if case .success = await roomProxy.timeline.sendMessage(body, html: nil, inReplyToEventID: nil, intentionalMentions: .empty) {
                return true
            }
            return false
        }
        guard ok else { return }
        sheetClosedByAction = true
        model.clearDraft()
        stack?.setSheetCoordinator(nil)
        flowParameters?.userIndicatorController.submitIndicator(UserIndicator(title: "Sent. Watch the chat for the workshop bot's reply."))
    }

    func presentDevLog() {
        guard let stack else { return }
        let devlog = ForkDevLogModel(rest: model.rest)
        let view = NavigationStack {
            ForkDevLogScreen(model: devlog) { [weak self] eventID, roomID in self?.jumpToMessage(eventID: eventID, roomID: roomID) }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { [weak self] in self?.stack?.setSheetCoordinator(nil) }
                            .accessibilityIdentifier("tj_devlog-done")
                    }
                }
        }
        .presentationDetents([.medium, .large])
        stack.setSheetCoordinator(ForkHostingCoordinator(view))
    }

    private func jumpToMessage(eventID: String, roomID: String) {
        stack?.setSheetCoordinator(nil)
        if model.isOpen { closeArtifacts() }
        if roomID == model.roomID {
            flow?.handleAppRoute(.event(eventID: eventID, roomID: roomID, via: []), animated: true)
        } else {
            flow?.handleAppRoute(.childEvent(eventID: eventID, roomID: roomID, via: []), animated: true)
        }
    }

    // MARK: Probe

    static func reportProbe(_ value: String) {
        #if TJ_DUO_PROBE
        ForkDuoProbe.shared.artifactsState = value
        ForkDuoProbe.shared.scheduleEmit("artifacts")
        #endif
    }
}

// MARK: - View

struct ForkRoomChromeView: View {
    let coordinator: ForkRoomChromeCoordinator
    let model: ForkArtifactsModel
    let state: ForkRoomChromeState

    @Environment(\.tabViewHorizontalSizeClass) private var tabSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    private var sizeClass: UserInterfaceSizeClass? {
        tabSizeClass ?? horizontalSizeClass
    }

    private var showsPane: Bool {
        model.layoutMode == .split && state.paneReady
    }

    var body: some View {
        let widths = ForkArtifactLayout.splitWidths(detailWidth: state.detailWidth)
        // The chat takes whatever the pane leaves, and the HStack is greedy, so the measured width is always the space
        // the detail column offers (G-A3 run 1 on iPad: with both children at fixed widths the HStack hugged them, kept
        // the width measured while the sidebar was still showing, and never grew once `.detailOnly` widened the column).
        HStack(spacing: 0) {
            coordinator.innerPresentable
                .frame(minWidth: 0, maxWidth: .infinity)
            if showsPane {
                Divider()
                ForkArtifactsPane(model: model, actions: coordinator.zoneActions)
                    .frame(width: widths.pane)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.detailWidth = $0 }
        .toolbar { ForkRoomToolbar(coordinator: coordinator, model: model, collapseDevLog: collapseDevLog, hasVerticalBar: state.hasVerticalBar, colorScheme: colorScheme).content }
        .background {
            ForkWindowMetricsReader { size, scene in coordinator.windowChanged(size: size, scene: scene) }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            ForkToolbarEdgeProbe { state.hasVerticalBar = $0 }
        }
        .onAppear { coordinator.viewAppeared(sizeClass: sizeClass) }
        .onChange(of: sizeClass) { _, newValue in coordinator.sizeClassChanged(newValue) }
        .onChange(of: coordinator.splitColumnVisibility) { _, newValue in coordinator.columnVisibilityChanged(newValue) }
    }

    /// §5.2: Dev log alone folds into "More" in a compact horizontal bar (27.1: only when there's no vertical bar).
    private var collapseDevLog: Bool {
        sizeClass == .compact && !state.hasVerticalBar
    }
}

/// Reads `toolbarVerticalEdge` on iOS 27.1+ and reports whether the bar is vertical (nothing before: always horizontal).
struct ForkToolbarEdgeProbe: View {
    let onChange: (Bool) -> Void

    var body: some View {
        #if TJ_SDK27
        if #available(iOS 27.1, *) {
            ForkToolbarEdgeReader27(onChange: onChange)
        }
        #endif
    }
}

#if TJ_SDK27
@available(iOS 27.1, *)
private struct ForkToolbarEdgeReader27: View {
    let onChange: (Bool) -> Void
    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { onChange(edge != nil) }
            .onChange(of: edge) { _, newValue in onChange(newValue != nil) }
            .accessibilityHidden(true)
    }
}
#endif

/// The room's rail items (D1): Artifacts, New chat, Dev log — merged by SwiftUI with upstream's items.
struct ForkRoomToolbar {
    let coordinator: ForkRoomChromeCoordinator
    let model: ForkArtifactsModel
    let collapseDevLog: Bool
    /// iOS 27.1 vertical bar (closed Duo): there the overlay badge draws and the system `.badge` does not (G-H6).
    let hasVerticalBar: Bool
    var colorScheme: ColorScheme = .light

    private var usesSystemBadge: Bool {
        ForkRailBadge.usesSystemBadge && !hasVerticalBar
    }

    private var symbolColor: UIColor {
        UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
    }

    @ToolbarContentBuilder
    var content: some ToolbarContent {
        #if TJ_SDK27
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .primaryAction) { artifactsButton }.visibilityPriority(.high)
            ToolbarItem(placement: .primaryAction) { newChatButton }.visibilityPriority(.high)
            ToolbarItem(placement: .primaryAction) { devLogItem }.visibilityPriority(.low)
        } else {
            plainItems
        }
        #else
        plainItems
        #endif
    }

    @ToolbarContentBuilder
    private var plainItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { artifactsButton }
        ToolbarItem(placement: .primaryAction) { newChatButton }
        ToolbarItem(placement: .primaryAction) { devLogItem }
    }

    private var artifactsButton: some View {
        let open = model.isOpen && model.layoutMode == .split
        let count = model.hasFetchedOnce ? model.entries.count : 0
        let badge = model.timerDoneBadge ? "!" : (count > 0 ? "\(count)" : nil)
        return Button {
            coordinator.toggleArtifacts()
        } label: {
            Label {
                Text(open ? "Close artifacts" : "Artifacts")
            } icon: {
                if usesSystemBadge || badge == nil {
                    Image(systemName: open ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                } else {
                    // Vertical bar (and before iOS 26): the count is drawn into the icon image itself; the bar draws neither
                    // an overlay nor `.badge` there (G-H6 run 1, closed Duo 27.1).
                    Image(uiImage: ForkBadgedSymbol.image(symbol: open ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                                                          badge: badge ?? "", color: open ? .tintColor : symbolColor))
                }
            }
        }
        .modifier(ForkToolbarBadge(text: badge, enabled: usesSystemBadge))
        .tint(open ? .accentColor : nil)
        .accessibilityValue(model.timerDoneBadge ? "Timer done" : (count > 0 ? "\(count) artifacts" : ""))
        .accessibilityIdentifier("tj_room-artifacts")
    }

    private var newChatButton: some View {
        Button {
            coordinator.presentStartChat()
        } label: {
            Label("New chat", systemImage: "plus")
        }
        .accessibilityIdentifier("tj_room-new-chat")
    }

    @ViewBuilder
    private var devLogItem: some View {
        if collapseDevLog {
            Menu {
                devLogButton
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("tj_room-more")
        } else {
            devLogButton
        }
    }

    private var devLogButton: some View {
        Button {
            coordinator.presentDevLog()
        } label: {
            Label("Dev log", systemImage: "list.bullet.rectangle")
        }
        .accessibilityIdentifier("tj_room-devlog")
    }
}

/// R4 (build 4): iOS 26+ horizontal toolbars draw a toolbar item's label as a bare symbol image and drop overlays, so the
/// count/"!" never showed under the iOS 27 horizontal bar (iPhone portrait). There the system badge (`.badge`) is used; the
/// 27.1 vertical bar is the reverse (overlay draws, `.badge` doesn't), so it keeps the overlay.
struct ForkToolbarBadge: ViewModifier {
    let text: String?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.badge(text.map { Text($0) })
        } else {
            content
        }
    }
}

/// The small count (or "Timer done" "!") badge on the room's Artifacts item (before iOS 26: drawn as an overlay).
struct ForkRailBadge: View {
    static var usesSystemBadge: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Color.red, in: Capsule())
                .offset(x: 8, y: -7)
                .accessibilityHidden(true)
        }
    }
}

/// An SF Symbol with a red count capsule drawn into the same image (original rendering), for bars that drop overlays.
enum ForkBadgedSymbol {
    static func image(symbol: String, badge: String, color: UIColor) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        guard let base = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal) else {
            return UIImage()
        }
        let font = UIFont.systemFont(ofSize: 10, weight: .bold)
        let text = NSAttributedString(string: badge, attributes: [.font: font, .foregroundColor: UIColor.white])
        let textSize = text.size()
        let badgeSize = CGSize(width: max(15, textSize.width + 8), height: 15)
        let inset = CGPoint(x: badgeSize.width * 0.55, y: 7)
        let size = CGSize(width: base.size.width + inset.x, height: base.size.height + inset.y)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            base.draw(at: CGPoint(x: 0, y: inset.y))
            let rect = CGRect(x: size.width - badgeSize.width, y: 0, width: badgeSize.width, height: badgeSize.height)
            UIColor.systemRed.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: badgeSize.height / 2).fill()
            text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
