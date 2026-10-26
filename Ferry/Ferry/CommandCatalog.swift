import Foundation
import Observation
import SwiftUI

// MARK: - Catalog models (Codable, lenient: unknown fields are ignored, and
// optional fields fall back to sensible defaults so a future FerryHelper
// catalog remains forward/backward compatible).

struct CommandItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    var insertText: String
    var subtitle: String?
    var icon: String?

    enum CodingKeys: String, CodingKey { case id, title, insertText, subtitle, icon }

    init(id: String, title: String, insertText: String, subtitle: String? = nil, icon: String? = nil) {
        self.id = id
        self.title = title
        self.insertText = insertText
        self.subtitle = subtitle
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        insertText = try c.decodeIfPresent(String.self, forKey: .insertText) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }
}

struct MentionTarget: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    var alias: String?
    var insertText: String?
    var icon: String?
    var commands: [CommandItem]

    enum CodingKeys: String, CodingKey { case id, title, alias, insertText, icon, commands }

    init(id: String, title: String, alias: String? = nil, insertText: String? = nil,
         icon: String? = nil, commands: [CommandItem] = []) {
        self.id = id
        self.title = title
        self.alias = alias
        self.insertText = insertText
        self.icon = icon
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        insertText = try c.decodeIfPresent(String.self, forKey: .insertText)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        commands = try c.decodeIfPresent([CommandItem].self, forKey: .commands) ?? []
    }

    /// SF Symbol for the row. A target with no `insertText` is a command
    /// container (e.g. FerryHelper), shown with a sparkles icon by default.
    var displayIcon: String {
        if let icon, !icon.isEmpty { return icon }
        return commands.isEmpty ? "at" : "sparkles"
    }
}

// MARK: - Mention context + insertion command

/// The active "@…" token under the caret: `range` is the full token (including
/// "@") in the text, `query` is the substring after "@" (may be empty).
struct MentionContext: Equatable {
    let range: NSRange
    let query: String

    /// Detect whether the caret sits right after an "@…" token whose "@" is at
    /// the start of the text or preceded by whitespace.
    static func detect(in text: String, cursor: Int) -> MentionContext? {
        let ns = text as NSString
        guard cursor > 0, cursor <= ns.length else { return nil }

        // The character right before the caret must not be whitespace.
        let prev = ns.substring(with: NSRange(location: cursor - 1, length: 1))
        guard !prev.isEmpty, prev.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        // Scan back to the start of the current word.
        var start = cursor - 1
        while start >= 0 {
            let ch = ns.substring(with: NSRange(location: start, length: 1))
            if ch.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { break }
            start -= 1
        }
        start += 1
        guard start < cursor, ns.substring(with: NSRange(location: start, length: 1)) == "@" else { return nil }

        let query = ns.substring(with: NSRange(location: start + 1, length: cursor - start - 1))
        return MentionContext(range: NSRange(location: start, length: cursor - start), query: query)
    }
}

/// An imperative "replace this range with this text" request passed from the
/// SwiftUI picker down into the `UITextView` so the caret can be placed right
/// after the inserted text.
struct TextInsertion: Equatable {
    let range: NSRange
    let text: String
}

// MARK: - Provider + store

protocol CommandCatalogProvider {
    func loadCatalog() throws -> [MentionTarget]
}

/// Loads a cached remote catalog if present, otherwise the built-in default.
/// The cached file lives at Application Support/command-catalog.json.
struct LocalCommandCatalogProvider: CommandCatalogProvider {
    func loadCatalog() throws -> [MentionTarget] {
        if let cached = Self.loadCachedCatalog() { return cached }
        return Self.builtIn
    }

    private static func loadCachedCatalog() -> [MentionTarget]? {
        guard let url = Self.catalogURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([MentionTarget].self, from: data)
    }

    static var catalogURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("command-catalog.json")
    }

    /// Built-in default catalog. Documented in the T6 report so the FerryHelper
    /// side can emit a matching JSON.
    static let builtIn: [MentionTarget] = [
        MentionTarget(id: "desktop", title: "电脑", insertText: "@电脑 ", icon: "desktopcomputer"),
        MentionTarget(id: "helper", title: "助手", alias: "FerryHelper", icon: "sparkles", commands: [
            CommandItem(id: "translate", title: "翻译", insertText: "/翻译 ", subtitle: "翻译文本", icon: "character.book.closed"),
            CommandItem(id: "ocr", title: "识别文字", insertText: "/识别文字 ", subtitle: "识别图片文字", icon: "text.viewfinder"),
            CommandItem(id: "summary", title: "总结", insertText: "/总结 ", subtitle: "总结内容", icon: "doc.text"),
        ]),
    ]
}

@MainActor @Observable
final class CommandCatalogStore {
    private(set) var targets: [MentionTarget]
    private let provider: any CommandCatalogProvider

    init(provider: any CommandCatalogProvider = LocalCommandCatalogProvider()) {
        self.provider = provider
        self.targets = (try? provider.loadCatalog()) ?? []
    }

    /// TODO: FerryHelper will publish a remote command catalog; this method
    /// will fetch and cache it. No network call is made for now.
    func refresh() {
        // TODO: fetch the remote catalog and replace `targets`.
    }
}

// MARK: - Picker UI

/// Dark popover list shown just above the input bar: mention targets (filtered
/// by query) or, once a command-container target is chosen, its commands.
/// Rows are ≥44pt; at most ~5 rows are visible before scrolling.
struct MentionPickerView: View {
    let targets: [MentionTarget]
    let query: String
    let activeTarget: MentionTarget?
    let onSelectTarget: (MentionTarget) -> Void
    let onSelectCommand: (CommandItem) -> Void

    private var filteredTargets: [MentionTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return targets }
        return targets.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.alias?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let activeTarget {
                if !activeTarget.commands.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(activeTarget.commands) { command in
                                commandRow(command)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredTargets) { target in
                            targetRow(target)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(maxWidth: 320)
        .background(Color(red: 30/255, green: 30/255, blue: 32/255),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    private func targetRow(_ target: MentionTarget) -> some View {
        Button { onSelectTarget(target) } label: {
            HStack(spacing: 10) {
                Image(systemName: target.displayIcon).foregroundStyle(.cyan).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.title).font(.body).foregroundStyle(.primary)
                    if let alias = target.alias {
                        Text(alias).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mention-\(target.id)")
    }

    private func commandRow(_ command: CommandItem) -> some View {
        Button { onSelectCommand(command) } label: {
            HStack(spacing: 10) {
                Image(systemName: command.icon ?? "chevron.right").foregroundStyle(.cyan).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title).font(.body).foregroundStyle(.primary)
                    if let subtitle = command.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("command-\(command.id)")
    }
}
