//
// TJ fork: "Add to Home Screen…" icon maker + install paths (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3.4, §13.3 (icon maker), §13.4 (path A, the main path: web-clip profile
// through Safari), §13.5 (path B: App Intent + Shortcuts "Add to Home Screen" with the icon saved to Photos).
// Apple image generation is user-driven only (`.imagePlaygroundSheet`, shown when supported); nothing runs in the background.
//

import ImagePlayground
import SafariServices
import SwiftUI

@Observable
final class ForkHomeScreenDraft {
    let link: ForkArtifactDeepLink
    let title: String
    let summary: String?
    var spec: ForkHomeIconSpec
    var emojiText: String
    var label: String
    var generated: UIImage?
    var status: String?
    var isWorking = false
    var flow = ForkHomeInstallFlow()
    /// The one-time loopback URL shown in the in-app Safari view (nil when not showing).
    var safariURL: ForkIdentifiedURL?
    var savedToPhotos = false

    init(link: ForkArtifactDeepLink, entry: ForkArtifactEntry) {
        self.link = link
        title = entry.title
        summary = entry.summary
        let spec = ForkHomeIconSpec.defaults(aid: entry.aid, symbol: entry.symbolName)
        self.spec = spec
        emojiText = spec.emoji
        label = String(entry.title.prefix(ForkHomeIconSpec.maxLabel))
    }

    var finalLabel: String {
        ForkHomeIconSpec.normalizedLabel(label, title: title)
    }

    func iconImage(side: CGFloat) -> UIImage? {
        ForkHomeIconRenderer.image(spec: spec, generated: generated, side: side)
    }

    func profile() throws -> Data {
        guard let icon = iconImage(side: 1024) else { throw CocoaError(.fileWriteUnknown) }
        let png = ForkHomeIconRenderer.downscaledPNG(icon, side: 400)
        return try ForkWebClipProfile.make(link: link, scheme: InfoPlistReader.app.appScheme,
                                           baseIdentifier: InfoPlistReader.main.baseBundleIdentifier,
                                           title: title, label: finalLabel, iconPNG: png)
    }
}

struct ForkHomeScreenSheet: View {
    @Bindable var draft: ForkHomeScreenDraft
    let onDone: () -> Void

    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @Environment(\.openURL) private var openURL
    @State private var isShowingPlayground = false
    @State private var isShowingOtherWays = false

    var body: some View {
        NavigationStack {
            Form {
                iconStep
                addStep
                settingsStep
                checkStep
                Section {
                    DisclosureGroup("Other ways", isExpanded: $isShowingOtherWays) { otherWays }
                        .accessibilityIdentifier("tj_home-other-ways")
                }
            }
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).accessibilityIdentifier("tj_home-done")
                }
            }
            .imagePlaygroundSheet(isPresented: $isShowingPlayground,
                                  concepts: [.text([draft.title, draft.summary].compactMap { $0 }.joined(separator: ". "))],
                                  onCompletion: { url in
                                      if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                                          draft.generated = image
                                          draft.status = nil
                                      } else {
                                          draft.status = "Apple's image couldn't be read; the emoji icon stays."
                                      }
                                  },
                                  onCancellation: { })
            .imagePlaygroundGenerationStyle(.emoji, in: [.emoji, .animation, .illustration, .sketch])
            .sheet(item: $draft.safariURL, onDismiss: { ForkProfileInstaller.shared.stop() }) { item in
                ForkSafariView(url: item.url).ignoresSafeArea()
            }
        }
        .accessibilityIdentifier("tj_home-sheet")
    }

    private var preview: some View {
        VStack(spacing: 8) {
            if let image = draft.iconImage(side: 240) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(radius: 3, y: 1)
            }
            Text(draft.finalLabel).font(.footnote).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Icon preview: \(draft.finalLabel)")
        .accessibilityIdentifier("tj_home-preview")
    }

    private var swatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(ForkHomeIconSpec.swatches.indices, id: \.self) { index in
                let spec = ForkHomeIconSpec(emoji: "", swatch: index)
                Button {
                    draft.spec.swatch = index
                    draft.generated = nil
                } label: {
                    Circle()
                        .fill(spec.color)
                        .frame(width: 34, height: 34)
                        .overlay { if draft.spec.swatch == index { Circle().strokeBorder(.primary, lineWidth: 3) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(index + 1)")
                .accessibilityAddTraits(draft.spec.swatch == index ? .isSelected : [])
                .accessibilityIdentifier("tj_home-swatch_\(index)")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Steps (E6 H1)

    private var iconStep: some View {
        Section {
            preview
            TextField("Label", text: $draft.label)
                .onChange(of: draft.label) { _, value in
                    if value.count > ForkHomeIconSpec.maxLabel { draft.label = String(value.prefix(ForkHomeIconSpec.maxLabel)) }
                }
                .accessibilityIdentifier("tj_home-label")
            HStack {
                Text("Emoji")
                TextField("Emoji", text: $draft.emojiText)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: draft.emojiText) { _, value in
                        if let emoji = ForkHomeIconSpec.normalizedEmoji(value) {
                            draft.spec.emoji = emoji
                            if value != emoji { draft.emojiText = emoji }
                            draft.generated = nil
                        }
                    }
                    .accessibilityIdentifier("tj_home-emoji")
            }
            swatches
            if supportsImagePlayground {
                Button {
                    isShowingPlayground = true
                } label: {
                    Label(draft.generated == nil ? "Generate with Apple" : "Generate again with Apple", systemImage: "sparkles")
                }
                .accessibilityIdentifier("tj_home-generate")
                if draft.generated != nil {
                    Button("Use the emoji icon instead") { draft.generated = nil }
                }
            }
        } header: {
            stepHeader(.icon, "Make the icon")
        } footer: {
            Text("Label: \(draft.finalLabel.count)/\(ForkHomeIconSpec.maxLabel) characters")
        }
    }

    private var addStep: some View {
        Section {
            Button {
                Task { await addWithProfile() }
            } label: {
                HStack {
                    Label("Add to Home Screen", systemImage: "plus.app")
                    if draft.isWorking { Spacer(); ProgressView() }
                }
            }
            .disabled(draft.isWorking)
            .accessibilityIdentifier("tj_home-add")
            Text(ForkHomeInstallFlow.safariLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tj_home-safari-line")
            if let status = draft.status {
                Text(status).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("tj_home-status")
            }
        } header: {
            stepHeader(.add, "Add it")
        } footer: {
            Text("A small profile that only adds this icon. It stays on this iPhone; nothing is uploaded.")
        }
    }

    private var settingsStep: some View {
        Section {
            Button {
                if let url = ForkHomeInstallFlow.settingsURL { openURL(url) }
                draft.flow.openedSettings()
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .disabled(draft.flow.state(of: .settings) == .upcoming)
            .accessibilityIdentifier("tj_home-open-settings")
            VStack(alignment: .leading, spacing: 6) {
                Text(ForkHomeInstallFlow.settingsLanding)
                Text(ForkHomeInstallFlow.settingsPath).fontWeight(.semibold)
                Text(ForkHomeInstallFlow.fallbackPath).foregroundStyle(.secondary)
                Text(ForkHomeInstallFlow.timeLimit).font(.caption).foregroundStyle(.secondary)
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tj_home-steps")
        } header: {
            stepHeader(.settings, "Install it in Settings")
        }
        .opacity(draft.flow.state(of: .settings) == .upcoming ? 0.5 : 1)
    }

    private var checkStep: some View {
        Section {
            Text("Back on your Home Screen, is \(draft.finalLabel) there? Tap it and \(draft.title) opens.")
                .font(.footnote)
            Button {
                onDone()
            } label: {
                Label("It's there. Done", systemImage: "checkmark.circle.fill")
            }
            .disabled(draft.flow.state(of: .check) == .upcoming)
            .accessibilityIdentifier("tj_home-check-done")
            Button("Not there? Start again") {
                draft.flow.startOver()
                draft.status = nil
            }
            .disabled(draft.flow.state(of: .check) == .upcoming)
            .accessibilityIdentifier("tj_home-start-over")
        } header: {
            stepHeader(.check, "Check")
        }
        .opacity(draft.flow.state(of: .check) == .upcoming ? 0.5 : 1)
    }

    private func stepHeader(_ step: ForkHomeInstallFlow.Step, _ title: String) -> some View {
        let state = draft.flow.state(of: step)
        return HStack(spacing: 6) {
            Image(systemName: state == .done ? "checkmark.circle.fill" : "\(step.rawValue).circle\(state == .active ? ".fill" : "")")
                .foregroundStyle(state == .upcoming ? Color.secondary : Color.accentColor)
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.rawValue): \(title)\(state == .done ? ", done" : "")")
    }

    private var otherWays: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make it with Shortcuts").font(.footnote.weight(.semibold))
            Button {
                saveIconToPhotos()
            } label: {
                Label(draft.savedToPhotos ? "Icon saved to Photos" : "Save icon to Photos", systemImage: draft.savedToPhotos ? "checkmark.circle" : "photo.badge.plus")
            }
            .accessibilityIdentifier("tj_home-save-photo")
            Text("Then open Shortcuts → + → add the action “Open artifact” (TJ Element) → choose \(draft.title) → tap ⓘ or Share → Add to Home Screen → tap the icon → Choose Photo → pick the saved icon → Add.")
                .font(.footnote)
            Button {
                UIPasteboard.general.string = draft.link.url(scheme: InfoPlistReader.app.appScheme).absoluteString
                draft.status = "Link copied. In Shortcuts you can also use “Open URLs” with it."
            } label: {
                Label("Copy link", systemImage: "link")
            }
            .accessibilityIdentifier("tj_home-copy-link")
        }
        .padding(.vertical, 4)
    }

    private func addWithProfile() async {
        draft.isWorking = true
        defer { draft.isWorking = false }
        do {
            let profile = try draft.profile()
            guard let url = await ForkProfileInstaller.shared.serve(profile: profile) else {
                draft.status = "Couldn't start the installer. Try again, or open Other ways below."
                return
            }
            draft.flow.profileServed()
            draft.status = nil
            draft.safariURL = ForkIdentifiedURL(url: url)
        } catch {
            draft.status = "Couldn't make the icon (\(error.localizedDescription))."
        }
    }

    private func saveIconToPhotos() {
        guard let image = draft.iconImage(side: 1024) else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        draft.savedToPhotos = true
    }
}

struct ForkIdentifiedURL: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// In-app Safari view: it downloads the profile while TJ Element stays in front (so the loopback listener can answer).
struct ForkSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) { }
}
