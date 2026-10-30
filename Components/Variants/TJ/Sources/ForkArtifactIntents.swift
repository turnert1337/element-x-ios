//
// TJ fork: App Intents for Home Screen apps, path B (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3.4, §13.5. "Open artifact" opens the app to the §13.1 deep link, which
// goes through the same router as a Home Screen icon (full screen + "← Thread"). The entity list is the on-device list of
// artifacts this app has seen (room id, artifact id, title only).
//

import AppIntents
import SwiftUI

nonisolated struct ForkArtifactEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artifact"
    static let defaultQuery = ForkArtifactEntityQuery()

    /// "<roomID>|<aid>" (`ForkArtifactDeepLink.entityID`).
    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(_ known: ForkKnownArtifact) {
        id = "\(known.roomID)|\(known.aid)"
        title = known.title
    }
}

nonisolated struct ForkArtifactEntityQuery: EntityQuery {
    func entities(for identifiers: [ForkArtifactEntity.ID]) async throws -> [ForkArtifactEntity] {
        let known = ForkKnownArtifacts.all()
        return identifiers.compactMap { id in known.first { "\($0.roomID)|\($0.aid)" == id }.map(ForkArtifactEntity.init) }
    }

    func suggestedEntities() async throws -> [ForkArtifactEntity] {
        ForkKnownArtifacts.all().map(ForkArtifactEntity.init)
    }
}

struct OpenArtifactIntent: AppIntent {
    static let title: LocalizedStringResource = "Open artifact"
    static let description = IntentDescription("Opens an artifact full screen in TJ Element, with a button back to its chat.")
    static let openAppWhenRun = true

    @Parameter(title: "Artifact")
    var artifact: ForkArtifactEntity

    init() { }

    init(artifact: ForkArtifactEntity) {
        self.artifact = artifact
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let link = ForkArtifactDeepLink(entityID: artifact.id) else { return .result() }
        // Through the app's own URL, so it takes exactly the Home Screen icon's path (upstream's openURL → the TJ router).
        _ = await UIApplication.shared.open(link.url(scheme: InfoPlistReader.app.appScheme))
        return .result()
    }
}

nonisolated struct ForkAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenArtifactIntent(),
                    phrases: ["Open \(\.$artifact) in \(.applicationName)", "Open an artifact in \(.applicationName)"],
                    shortTitle: "Open artifact",
                    systemImageName: "square.stack.3d.up")
    }
}
