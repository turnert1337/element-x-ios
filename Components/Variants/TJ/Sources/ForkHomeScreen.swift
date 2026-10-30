//
// TJ fork: Home Screen apps, pure layer (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3.4, §13.1 (deep link), §13.3 (icon defaults), §13.4 (web-clip profile).
// Everything here is nonisolated and side-effect free (the icon renderer aside), so the unit tests run against it directly.
//

import CryptoKit
import Foundation
import SwiftUI
import UIKit

// MARK: - Deep link (§13.1)

nonisolated struct ForkArtifactDeepLink: Equatable, Hashable, Sendable {
    static let host = "artifact"

    let roomID: String
    let aid: String

    init?(roomID: String, aid: String) {
        guard Self.isValidRoomID(roomID), ForkArtifactConstants.isValidAID(aid) else { return nil }
        self.roomID = roomID
        self.aid = aid
    }

    /// `!` then 1–255 characters without whitespace, `/`, `?` or `#` (v12 room ids have no server part; older ones do).
    static func isValidRoomID(_ value: String) -> Bool {
        value.wholeMatch(of: /![^\s\/?#]{1,255}/) != nil
    }

    /// Only `A-Z a-z 0-9 - . _ ~` stay bare, so `!` → `%21` and `:` → `%3A`.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func url(scheme: String) -> URL {
        // Safe: the scheme is the app's own and both values are fully percent-encoded.
        URL(string: "\(scheme)://\(Self.host)?room=\(Self.encode(roomID))&a=\(Self.encode(aid))")!
    }

    /// nil for anything that isn't exactly our link, so upstream routing sees every other URL untouched.
    static func parse(_ url: URL, scheme: String) -> ForkArtifactDeepLink? {
        guard let urlScheme = url.scheme, urlScheme.caseInsensitiveCompare(scheme) == .orderedSame,
              url.host() == host,
              url.path().isEmpty || url.path() == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return nil
        }
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard let room = value("room"), let aid = value("a") else { return nil }
        return ForkArtifactDeepLink(roomID: room, aid: aid)
    }

    /// The App Intent entity id (§13.5).
    var entityID: String {
        "\(roomID)|\(aid)"
    }

    init?(entityID: String) {
        let parts = entityID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        self.init(roomID: parts[0], aid: parts[1])
    }

    /// First 16 hex of sha256("<roomID>|<aid>"): the stable profile identifier part.
    var stableHash: String {
        String(ForkArtifactSHA.hex(entityID).prefix(16))
    }

    /// A UUID derived from sha256(seed) (version 5 / RFC 4122 variant bits set), so the same artifact always gets the same
    /// profile UUID and re-adding it replaces the installed icon.
    static func stableUUID(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }
}

// MARK: - Icon spec (§13.3)

nonisolated struct ForkHomeIconSpec: Equatable, Sendable {
    /// 10 swatches (hex), tuned for a white-ish emoji to read on all of them.
    static let swatches: [UInt32] = [0x1F6FEB, 0x0E9F6E, 0xE3562F, 0x8250DF, 0xD4A72C,
                                     0xBF3989, 0x0F766E, 0x334155, 0xF97316, 0x2563EB]
    static let maxLabel = 20

    var emoji: String
    var swatch: Int

    static func defaultSwatch(aid: String) -> Int {
        let first = Array(SHA256.hash(data: Data(aid.utf8))).first ?? 0
        return Int(first) % swatches.count
    }

    /// The artifact's SF Symbol mapped to an emoji; unknown symbols get 🧩.
    static func defaultEmoji(symbol: String) -> String {
        let table: [(String, String)] = [("sparkles", "✨"), ("timer", "⏱️"), ("stopwatch", "⏱️"), ("clock", "🕒"),
                                         ("point.3.connected", "🗺️"), ("map", "🗺️"), ("gamecontroller", "🎮"),
                                         ("chart", "📊"), ("doc", "📄"), ("text", "📝"), ("pencil", "✏️"),
                                         ("music", "🎵"), ("photo", "🖼️"), ("camera", "📷"), ("globe", "🌐"),
                                         ("heart", "❤️"), ("star", "⭐️"), ("bolt", "⚡️"), ("flame", "🔥"),
                                         ("leaf", "🌿"), ("cube", "🧊"), ("bird", "🐦"), ("airplane", "✈️"),
                                         ("calendar", "📅"), ("checklist", "✅"), ("list", "📋"), ("book", "📖"),
                                         ("cart", "🛒"), ("dollarsign", "💵"), ("house", "🏠"), ("terminal", "💻")]
        for (prefix, emoji) in table where symbol.hasPrefix(prefix) || symbol.contains(prefix) {
            return emoji
        }
        return "🧩"
    }

    static func defaults(aid: String, symbol: String) -> ForkHomeIconSpec {
        ForkHomeIconSpec(emoji: defaultEmoji(symbol: symbol), swatch: defaultSwatch(aid: aid))
    }

    /// Keeps the first character (grapheme) only; empty → nil.
    static func normalizedEmoji(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)
    }

    /// Trimmed, at most 20 characters; empty falls back to the title (itself cut to 20).
    static func normalizedLabel(_ label: String, title: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        return String(base.prefix(maxLabel))
    }

    var color: Color {
        let hex = Self.swatches[max(0, min(swatch, Self.swatches.count - 1))]
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The full-bleed square icon (iOS applies its own mask; `Precomposed` keeps it from adding gloss).
struct ForkHomeIconView: View {
    let spec: ForkHomeIconSpec
    var generated: UIImage?
    var side: CGFloat = 1024

    var body: some View {
        ZStack {
            if let generated {
                Color.white
                Image(uiImage: generated)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [spec.color.opacity(0.85), spec.color], startPoint: .top, endPoint: .bottom)
                Text(spec.emoji)
                    .font(.system(size: side * 0.6))
                    .minimumScaleFactor(0.2)
                    .lineLimit(1)
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

enum ForkHomeIconRenderer {
    /// A `side` × `side` px PNG (scale 1).
    static func png(spec: ForkHomeIconSpec, generated: UIImage?, side: CGFloat) -> Data? {
        image(spec: spec, generated: generated, side: side)?.pngData()
    }

    static func image(spec: ForkHomeIconSpec, generated: UIImage?, side: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: ForkHomeIconView(spec: spec, generated: generated, side: side))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: side, height: side)
        return renderer.uiImage
    }

    /// Downscales to `side` px (scale 1), for the profile's ≤ 400 px / < 1 MB icon.
    static func downscaledPNG(_ image: UIImage, side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.pngData { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}

// MARK: - Web-clip profile (§13.4)

nonisolated enum ForkWebClipProfile {
    static let contentType = "application/x-apple-aspen-config"

    /// The XML `.mobileconfig` for one artifact. `baseIdentifier` is the app's bundle id.
    static func make(link: ForkArtifactDeepLink, scheme: String, baseIdentifier: String, title: String, label: String, iconPNG: Data) throws -> Data {
        let hash = link.stableHash
        let identifier = "\(baseIdentifier).tj.webclip.\(hash)"
        let clip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier + ".clip",
            "PayloadUUID": ForkArtifactDeepLink.stableUUID(link.entityID + "|clip"),
            "PayloadDisplayName": "TJ Element: \(title)",
            "URL": link.url(scheme: scheme).absoluteString,
            "Label": label,
            "Icon": iconPNG,
            "Precomposed": true,
            "FullScreen": true,
            "IsRemovable": true
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": ForkArtifactDeepLink.stableUUID(link.entityID),
            "PayloadDisplayName": "TJ Element: \(title)",
            "PayloadOrganization": "TJ Element",
            "PayloadDescription": "Adds “\(label)” to your Home Screen. It opens \(title) in TJ Element. Nothing leaves this iPhone.",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [clip]
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}

// MARK: - Artifacts the app has seen (App Intent entity list, §13.5)

nonisolated struct ForkKnownArtifact: Codable, Equatable, Sendable {
    let roomID: String
    let aid: String
    let title: String
    let icon: String
}

nonisolated enum ForkKnownArtifacts {
    static let key = "tj.homescreen.known"
    static let cap = 200

    static func all(defaults: UserDefaults = .standard) -> [ForkKnownArtifact] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ForkKnownArtifact].self, from: data)) ?? []
    }

    /// Replaces the room's rows with `entries` (newest rooms first, capped).
    static func record(roomID: String, entries: [(aid: String, title: String, icon: String)], defaults: UserDefaults = .standard) {
        var rows = all(defaults: defaults).filter { $0.roomID != roomID }
        rows.insert(contentsOf: entries.map { ForkKnownArtifact(roomID: roomID, aid: $0.aid, title: $0.title, icon: $0.icon) }, at: 0)
        let capped = Array(rows.prefix(cap))
        guard capped != all(defaults: defaults), let data = try? JSONEncoder().encode(capped) else { return }
        defaults.set(data, forKey: key)
    }
}
