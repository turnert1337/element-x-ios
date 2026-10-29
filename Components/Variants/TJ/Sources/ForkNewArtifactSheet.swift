//
// TJ fork: New artifact sheet with the required Xcode | NAS picker (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, §5.6 (S1, D7, D14) and §5.6b (Request a change).
// No pipe is preselected and Notify chat stays disabled until a pipe AND text are there. Everything typed lives in
// `ForkArtifactsModel.draft`, so a fold that dismisses the sheet loses nothing.
//

import SwiftUI

struct ForkNewArtifactSheet: View {
    @Bindable var model: ForkArtifactsModel
    let isEncrypted: Bool
    let onCancel: () -> Void
    let onSend: () async -> Void

    @FocusState private var textFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if model.draft.isChange {
                    Section {
                        HStack {
                            Text("Change \(model.draft.targetTitle ?? "artifact")").font(.headline)
                            Spacer()
                            ForkPipeBadge(pipe: .nas)
                        }
                        .accessibilityIdentifier("tj_new-artifact-change-title")
                    }
                } else {
                    Section {
                        ForkPipePicker(selection: $model.draft.pipe)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("**Xcode:** native SwiftUI, durable, arrives in a TestFlight update.")
                            Text("**NAS:** web page on the NAS, an agent builds and changes it in minutes, no build.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } header: {
                        HStack {
                            Text("Which pipe?")
                            Spacer()
                            Text("required").font(.caption)
                        }
                    }

                    Section("Title (optional)") {
                        TextField("Color picker", text: $model.draft.title)
                            .onChange(of: model.draft.title) { _, value in
                                if ForkArtifactRequest.length(value) > ForkArtifactRequest.maxTitle {
                                    model.draft.title = String(value.unicodeScalars.prefix(ForkArtifactRequest.maxTitle).map(Character.init))
                                }
                            }
                            .accessibilityIdentifier("tj_new-artifact-title")
                    }
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        if model.draft.text.isEmpty {
                            Text(model.draft.isChange ? "What should change?" : "What do you want?")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $model.draft.text)
                            .focused($textFocused)
                            .frame(minHeight: 120)
                            .accessibilityIdentifier("tj_new-artifact-text")
                    }
                    let count = ForkArtifactRequest.length(model.draft.text)
                    if count > 3500 {
                        Text("\(count) / 4000")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(count > 4000 ? Color.red : Color.secondary)
                    }
                } header: {
                    Text(model.draft.isChange ? "What should change?" : "What do you want?")
                }

                if isEncrypted {
                    Section {
                        Label("This chat is encrypted: the workshop agent can't read requests here.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("tj_new-artifact-encrypted-warning")
                    }
                }

                Section {
                    Button {
                        Task { await onSend() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.draft.isSending { ProgressView().padding(.trailing, 6) }
                            Text("Notify chat").bold()
                            Spacer()
                        }
                    }
                    .disabled(!model.draft.canSend)
                    .accessibilityHint(model.draft.pipe == nil ? "Pick Xcode or NAS first" : "")
                    .accessibilityIdentifier("tj_new-artifact-notify")

                    if let error = model.draft.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("tj_new-artifact-error")
                    }
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle(model.draft.isChange ? "Request a change" : "New artifact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("tj_new-artifact-cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("tj_new-artifact-sheet")
    }

    private var footer: String {
        switch model.draft.pipe {
        case .nas?: "NAS: an agent starts on it when the workshop runner is up."
        case .xcode?: "Xcode: waits for a workshop session and a TestFlight update."
        case nil: "NAS: an agent starts on it when the workshop runner is up. Xcode: waits for a workshop session and a TestFlight update."
        }
    }
}

/// A two-button segmented control that can show "nothing selected" (SwiftUI's `.segmented` needs a selection).
struct ForkPipePicker: View {
    @Binding var selection: ForkArtifactPipe?

    var body: some View {
        HStack(spacing: 0) {
            segment(.xcode, title: "Xcode")
            Divider().frame(height: 22)
            segment(.nas, title: "NAS")
        }
        .padding(2)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tj_new-artifact-pipe")
    }

    private func segment(_ pipe: ForkArtifactPipe, title: String) -> some View {
        let selected = selection == pipe
        return Button {
            selection = pipe
        } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(selected ? Color(uiColor: .systemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pipe == .nas ? "Deliver through NAS" : "Deliver through Xcode")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("tj_new-artifact-pipe-\(pipe.rawValue)")
    }
}
