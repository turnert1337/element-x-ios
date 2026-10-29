//
// TJ fork: the Artifacts zone views (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.3 (compact pushed screen, regular side pane with an in-content
// header strip + zone rail, full screen), §5.4 (D16 chip, change note), §5.6b (Request a change).
// Both pipes land in this one zone; every artifact carries its pipe badge (D7).
//

import SwiftUI

/// What the zone can ask the room chrome to do.
struct ForkArtifactsActions {
    var backToChat: () -> Void = { }
    var newArtifact: () -> Void = { }
    var requestChange: (ForkArtifactEntry) -> Void = { _ in }
    var enterFullScreen: () -> Void = { }
}

// MARK: - Shared pieces

struct ForkPipeBadge: View {
    let pipe: ForkArtifactPipe

    var body: some View {
        Text(pipe.badge)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()                    // the badge never truncates ("Xco…"); the title gives way instead
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(pipe == .nas ? Color.teal : Color.indigo)
            .background((pipe == .nas ? Color.teal : Color.indigo).opacity(0.15), in: Capsule())
            .accessibilityLabel(pipe == .nas ? "Delivered through NAS" : "Delivered through Xcode")
    }
}

struct ForkArtifactTitleLabel: View {
    let entry: ForkArtifactEntry?

    var body: some View {
        if let entry {
            HStack(spacing: 6) {
                Image(systemName: entry.symbolName)
                Text(entry.title).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                ForkPipeBadge(pipe: entry.pipe)
            }
            .font(.headline)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tj_artifacts-title")
        } else {
            Text("Artifacts").font(.headline)
        }
    }
}

/// The D16 chip and the §5.3 "Draft kept" chip; never blocks the canvas.
/// Shown in the header (compact principal / split header strip), never over the canvas: a SwiftUI control drawn over the
/// WKWebView doesn't receive taps (UIKit routes them to the web view).
struct ForkArtifactChips: View {
    let model: ForkArtifactsModel
    let actions: ForkArtifactsActions

    static func hasChip(_ model: ForkArtifactsModel) -> Bool {
        (model.selectedEntry.flatMap { model.htmlStates[$0.aid]?.chipVersion } != nil) || (model.draftKept && !model.draft.isEmpty)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let aid = model.selectedEntry?.aid, let version = model.htmlStates[aid]?.chipVersion {
                Button {
                    model.reload(aid: aid)
                } label: {
                    Label("Updated to v\(version): reload", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tj_artifacts-reload-chip")
            }
            if model.draftKept, !model.draft.isEmpty {
                Button {
                    actions.newArtifact()
                } label: {
                    Label("Draft kept: tap + to continue", systemImage: "square.and.pencil")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tj_artifacts-draft-chip")
            }
        }
    }
}

/// Dispatches the selected artifact to the web view, a native view, the "Arrives" card, or an error state.
struct ForkArtifactCanvas: View {
    let model: ForkArtifactsModel
    var isFullScreenHost = false

    var body: some View {
        Group {
            if model.isFullScreen, !isFullScreenHost {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.largeTitle)
                    Text("Showing full screen")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let entry = model.selectedEntry {
                content(for: entry)
            } else {
                ForkArtifactsEmptyState(model: model)
            }
        }
    }

    @ViewBuilder
    private func content(for entry: ForkArtifactEntry) -> some View {
        switch entry.source {
        case .html:
            ForkHTMLArtifactView(model: model, entry: entry)
                .id(entry.aid)
        case .native(let id):
            switch ForkNativeArtifacts.decision(for: entry) {
            case .render:
                if let make = ForkNativeArtifacts.registry[id] {
                    make(model).id(entry.aid)
                } else {
                    ForkArrivesInUpdateCard(entry: entry, needsBuild: entry.minBuild)
                }
            case .arrivesInUpdate(let needsBuild):
                ForkArrivesInUpdateCard(entry: entry, needsBuild: needsBuild)
            }
        case .unsupported:
            ForkArtifactMessage(symbol: "exclamationmark.triangle", title: "Unsupported source",
                                detail: "\(entry.title) points somewhere TJ Element doesn't load from. Only Matrix media (mxc://) is shown.")
        }
    }
}

struct ForkHTMLArtifactView: View {
    let model: ForkArtifactsModel
    let entry: ForkArtifactEntry

    var body: some View {
        let state = model.htmlStates[entry.aid]
        Group {
            if model.liveHosts[entry.aid] != nil, let host = ForkArtifactWebPool.shared.host(forKey: model.hostKey(entry.aid)) {
                ForkArtifactWebContainer(host: host) { model.noteTouch(aid: entry.aid) }
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if let error = state?.error, state?.readyVersion == nil {
                ForkArtifactMessage(symbol: "exclamationmark.octagon", title: "Can't show \(entry.title)", detail: error)
            } else {
                ProgressView("Loading \(entry.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(entry.aid)-\(state?.readyVersion ?? -1)-\(model.liveHosts[entry.aid] ?? -1)") {
            await model.display(aid: entry.aid)
        }
    }
}

struct ForkArtifactMessage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ForkArtifactsEmptyState: View {
    let model: ForkArtifactsModel

    var body: some View {
        if let error = model.fetchError, model.entries.isEmpty {
            ForkArtifactMessage(symbol: "wifi.exclamationmark", title: error, detail: "Pull the zone open again to retry.")
        } else if !model.hasFetchedOnce {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ForkArtifactMessage(symbol: "square.stack.3d.up", title: "No artifacts in this chat yet. Tap + to ask for one.", detail: "")
                .accessibilityIdentifier("tj_artifacts-empty")
        }
    }
}

/// The header menu: Request a change (NAS only) and Refresh.
struct ForkArtifactHeaderMenu: View {
    let model: ForkArtifactsModel
    let actions: ForkArtifactsActions

    var body: some View {
        Menu {
            if let entry = model.selectedEntry, entry.pipe == .nas, entry.isHTML {
                Button { actions.requestChange(entry) } label: { Label("Request a change", systemImage: "wand.and.sparkles") }
                    .accessibilityIdentifier("tj_artifacts-request-change")
            }
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            if let entry = model.selectedEntry, let summary = entry.summary, !summary.isEmpty {
                Section(summary) { }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Artifact options")
        }
        .accessibilityIdentifier("tj_artifacts-header-menu")
    }
}

// MARK: - Compact: the pushed zone (the main screen)

struct ForkArtifactsScreen: View {
    let model: ForkArtifactsModel
    let actions: ForkArtifactsActions

    var body: some View {
        ForkArtifactCanvas(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { ForkArtifactChangeNote(model: model).allowsHitTesting(false) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { model.zoneAppeared() }
            .onDisappear { model.zoneDisappeared() }
            .accessibilityIdentifier("tj_artifacts-screen")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                if ForkArtifactChips.hasChip(model) {
                    ForkArtifactChips(model: model, actions: actions)
                } else {
                    ForkArtifactTitleLabel(entry: model.selectedEntry)
                }
                ForkArtifactHeaderMenu(model: model, actions: actions)
            }
        }
        let entries = model.entries
        let inline = entries.count > 5 ? Array(entries.prefix(4)) : entries
        ForEach(inline) { entry in
            ToolbarItem(placement: .primaryAction) {
                ForkArtifactToolbarButton(model: model, entry: entry)
            }
        }
        if entries.count > 5 {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(entries.dropFirst(4)) { entry in
                        Button { model.selectedAID = entry.aid } label: { Label(entry.title, systemImage: entry.symbolName) }
                    }
                } label: {
                    Label("All artifacts", systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("tj_artifacts-all")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: actions.newArtifact) { Label("New artifact", systemImage: "plus") }
                .accessibilityIdentifier("tj_artifacts-new")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: actions.enterFullScreen) { Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                .disabled(model.selectedEntry == nil)
                .accessibilityIdentifier("tj_artifacts-fullscreen")
        }
    }
}

struct ForkArtifactToolbarButton: View {
    let model: ForkArtifactsModel
    let entry: ForkArtifactEntry

    var body: some View {
        let selected = model.selectedEntry?.aid == entry.aid
        Button {
            model.selectedAID = entry.aid
        } label: {
            Label(entry.title, systemImage: entry.symbolName)
        }
        .tint(selected ? .accentColor : nil)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityLabel("Artifact: \(entry.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tj_artifact_\(entry.aid)")
    }
}

struct ForkArtifactChangeNote: View {
    let model: ForkArtifactsModel

    var body: some View {
        if let note = model.headerNote, note.aid == model.selectedEntry?.aid {
            Text(note.text)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 12)
                .transition(.opacity)
                .accessibilityIdentifier("tj_artifacts-change-note")
        }
    }
}

// MARK: - Regular: the side pane (in-content header strip + zone rail)

struct ForkArtifactsPane: View {
    let model: ForkArtifactsModel
    let actions: ForkArtifactsActions

    var body: some View {
        HStack(spacing: 0) {
            ForkArtifactCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { ForkArtifactsPaneHeader(model: model, actions: actions) }
            ForkArtifactRail(model: model, actions: actions)
        }
        .onAppear { model.zoneAppeared() }
        .onDisappear { model.zoneDisappeared() }
        .accessibilityIdentifier("tj_artifacts-pane")
    }
}

struct ForkArtifactsPaneHeader: View {
    let model: ForkArtifactsModel
    let actions: ForkArtifactsActions

    var body: some View {
        HStack(spacing: 8) {
            ForkArtifactTitleLabel(entry: model.selectedEntry)
            ForkArtifactChips(model: model, actions: actions)
            if let note = model.headerNote, note.aid == model.selectedEntry?.aid {
                Text(note.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("tj_artifacts-change-note")
            }
            Spacer(minLength: 4)
            ForkArtifactHeaderMenu(model: model, actions: actions)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.regularMaterial)
        .accessibilityIdentifier("tj_artifacts-pane-header")
    }
}

/// A trailing column of 48 pt circles at a 60 pt pitch: ✕ back to chat, one per artifact, + New artifact, ⤢ Full screen.
struct ForkArtifactRail: View {
    let model: ForkArtifactsModel
    let actions: ForkArtifactsActions

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                circle("xmark", label: "Back to chat", id: "tj_artifacts-rail-close", action: actions.backToChat)
                ForEach(model.entries) { entry in
                    let selected = model.selectedEntry?.aid == entry.aid
                    circle(entry.symbolName, label: "Artifact: \(entry.title)", id: "tj_artifact_\(entry.aid)", selected: selected) {
                        model.selectedAID = entry.aid
                    }
                    .contextMenu {
                        if entry.pipe == .nas, entry.isHTML {
                            Button { actions.requestChange(entry) } label: { Label("Request a change", systemImage: "wand.and.sparkles") }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) { ForkPipeDot(pipe: entry.pipe) }
                }
                circle("plus", label: "New artifact", id: "tj_artifacts-new", action: actions.newArtifact)
                circle("arrow.up.left.and.arrow.down.right", label: "Full screen", id: "tj_artifacts-fullscreen", action: actions.enterFullScreen)
                    .disabled(model.selectedEntry == nil)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .frame(width: 64)
        .accessibilityIdentifier("tj_artifacts-rail")
    }

    private func circle(_ symbol: String, label: String, id: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 48, height: 48)
                .modifier(ForkRailCircleBackground(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

struct ForkPipeDot: View {
    let pipe: ForkArtifactPipe

    var body: some View {
        Text(pipe == .nas ? "N" : "X")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(pipe == .nas ? Color.teal : Color.indigo, in: Circle())
            .accessibilityHidden(true)
    }
}

struct ForkRailCircleBackground: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if selected {
            content.background(Color.accentColor, in: Circle())
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}
