import Foundation
import Observation
import SwiftUI
import os

// MARK: - Catalog models (Codable, lenient: unknown fields are ignored, and
// optional fields fall back to sensible defaults so a future FerryHelper
// catalog remains forward/backward compatible).

struct CommandItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    var insertText: String
    var subtitle: String?
    var icon: String?
    var aliases: [String]
    var requiresArgument: Bool

    enum CodingKeys: String, CodingKey { case id, title, insertText, subtitle, icon, aliases, requiresArgument }

    init(id: String, title: String, insertText: String, subtitle: String? = nil,
         icon: String? = nil, aliases: [String] = [], requiresArgument: Bool = false) {
        self.id = id
        self.title = title
        self.insertText = insertText
        self.subtitle = subtitle
        self.icon = icon
        self.aliases = aliases
        self.requiresArgument = requiresArgument
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        insertText = try c.decodeIfPresent(String.self, forKey: .insertText) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        requiresArgument = try c.decodeIfPresent(Bool.self, forKey: .requiresArgument) ?? false
    }
}

struct MentionTarget: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    var alias: String?
    var aliases: [String]
    var subtitle: String?
    var insertText: String?
    var icon: String?
    var commands: [CommandItem]

    enum CodingKeys: String, CodingKey { case id, title, alias, aliases, subtitle, insertText, icon, commands }

    init(id: String, title: String, alias: String? = nil, aliases: [String] = [], subtitle: String? = nil,
         insertText: String? = nil, icon: String? = nil, commands: [CommandItem] = []) {
        self.id = id
        self.title = title
        self.alias = alias
        self.aliases = aliases
        self.subtitle = subtitle
        self.insertText = insertText
        self.icon = icon
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
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

    /// Whether this catalog entry is the one published for the assistant named
    /// `name` (exact, case-insensitive — title, alias or alias list).
    func matchesAssistant(_ name: String) -> Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        if title.localizedCaseInsensitiveCompare(target) == .orderedSame { return true }
        if let alias, alias.localizedCaseInsensitiveCompare(target) == .orderedSame { return true }
        return aliases.contains { $0.localizedCaseInsensitiveCompare(target) == .orderedSame }
    }

    /// Case-insensitive match against title, alias, aliases, subtitle, and
    /// each command's name/description/aliases.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(q) { return true }
        if alias?.localizedCaseInsensitiveContains(q) == true { return true }
        if aliases.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
        if subtitle?.localizedCaseInsensitiveContains(q) == true { return true }
        return commands.contains { command in
            command.title.localizedCaseInsensitiveContains(q)
                || (command.subtitle?.localizedCaseInsensitiveContains(q) ?? false)
                || command.aliases.contains(where: { $0.localizedCaseInsensitiveContains(q) })
        }
    }
}

// MARK: - Remote (FerryHelper) catalog format

/// `GET http://<host>:42830/commands.json` -> `{"version":1,"generated_at":…,
/// "groups":[{"assistant":…,"commands":[…]}…]}`. Unknown fields are ignored;
/// `version` must be exactly 1.
struct RemoteCommandCatalog: Decodable {
    let version: Int
    let groups: [RemoteCommandGroup]

    enum CodingKeys: String, CodingKey { case version, groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        groups = try c.decodeIfPresent([RemoteCommandGroup].self, forKey: .groups) ?? []
    }

    static func map(_ remote: RemoteCommandCatalog) -> [MentionTarget]? {
        guard remote.version == 1 else { return nil }
        return remote.groups.map { Self.map(group: $0) }
    }

    static func map(group: RemoteCommandGroup) -> MentionTarget {
        // Keep iOS navigation IDs stable while displaying Windows' "助手".
        let key = group.assistant == "助手" ? "helper" : group.assistant
        let commands = group.commands.map { command in
            CommandItem(id: command.name, title: command.name,
                        insertText: command.insert_text ?? "",
                        subtitle: command.description, icon: nil, aliases: command.aliases ?? [],
                        requiresArgument: command.requires_argument ?? false)
        }
        if commands.count == 1 {
            let command = commands[0]
            return MentionTarget(id: key, title: group.assistant, alias: group.assistant,
                                 aliases: command.aliases, subtitle: command.subtitle,
                                 insertText: command.insertText, icon: nil, commands: [])
        }
        return MentionTarget(id: key, title: group.assistant, alias: group.assistant,
                             aliases: [], subtitle: nil, insertText: nil, icon: nil, commands: commands)
    }
}

struct RemoteCommandGroup: Decodable {
    let assistant: String
    let commands: [RemoteCommand]

    enum CodingKeys: String, CodingKey { case assistant, commands }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assistant = try c.decode(String.self, forKey: .assistant)
        commands = try c.decodeIfPresent([RemoteCommand].self, forKey: .commands) ?? []
    }
}

struct RemoteCommand: Decodable {
    let name: String
    let insert_text: String?
    let description: String?
    let requires_argument: Bool?
    let aliases: [String]?

    enum CodingKeys: String, CodingKey { case name, insert_text, description, requires_argument, aliases }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        insert_text = try c.decodeIfPresent(String.self, forKey: .insert_text)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        requires_argument = try c.decodeIfPresent(Bool.self, forKey: .requires_argument)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
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
/// after the inserted text. `id` makes each request unique so the text view can
/// apply it exactly once even if `updateUIView` runs several times before the
/// parent clears the binding.
struct TextInsertion: Equatable {
    let id: UUID
    let range: NSRange
    let text: String
}

// MARK: - Provider + store

protocol CommandCatalogProvider {
    func loadCatalog() throws -> [MentionTarget]
}

/// Loads a cached remote catalog if present, otherwise the built-in default.
/// The cached file lives at Application Support/command-catalog.json and is
/// stored in the remote `{"version","groups"}` format (with a legacy array
/// fallback for older caches).
struct LocalCommandCatalogProvider: CommandCatalogProvider {
    func loadCatalog() throws -> [MentionTarget] {
        if let cached = Self.loadCachedCatalog() { return cached }
        return Self.builtIn
    }

    private static func loadCachedCatalog() -> [MentionTarget]? {
        guard let url = Self.catalogURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let remote = try? JSONDecoder().decode(RemoteCommandCatalog.self, from: data),
           let mapped = RemoteCommandCatalog.map(remote) {
            return mapped
        }
        // Legacy local format (a top-level array of MentionTarget).
        return try? JSONDecoder().decode([MentionTarget].self, from: data)
    }

    static var catalogURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("command-catalog.json")
    }

    /// Offline fallback mirrors actual FerryHelper CommandRegistry
    /// rather than offering non-existent translation/OCR/summary commands.
    static let builtIn: [MentionTarget] = [
        MentionTarget(id: "desktop", title: "电脑", alias: "电脑", aliases: ["PC", "desktop"],
                      subtitle: "唤醒电脑", insertText: "@电脑 ", icon: "desktopcomputer"),
        MentionTarget(id: "helper", title: "助手", alias: "FerryHelper", icon: "sparkles", commands: [
            CommandItem(id: "截图", title: "截图", insertText: "/截图",
                        subtitle: "截取电脑屏幕并发送", icon: "camera.viewfinder"),
            CommandItem(id: "找", title: "找文件", insertText: "/找 ",
                        subtitle: "按文件名、路径、日期和类型查找", icon: "magnifyingglass",
                        aliases: ["查找"], requiresArgument: true),
            CommandItem(id: "发文件", title: "发文件", insertText: "/发文件 ",
                        subtitle: "发送白名单目录中的指定文件", icon: "folder",
                        requiresArgument: true),
            CommandItem(id: "帮助", title: "帮助", insertText: "/帮助",
                        subtitle: "查看电脑支持的指令", icon: "questionmark.circle"),
            CommandItem(id: "命令列表", title: "命令列表", insertText: "/命令列表",
                        subtitle: "查看完整指令清单", icon: "list.bullet"),
        ]),
    ]
}

/// Fetches the FerryHelper catalog over a dedicated ephemeral session with
/// short timeouts. Never sends an Authorization header.
struct RemoteCommandCatalogFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Prefer the authenticated Go relay; only the fallback uses port 42830.
    func fetch(endpoint: ServerEndpoint, token: String?) async throws
        -> (raw: Data, targets: [MentionTarget]) {
        var request = URLRequest(url: endpoint.url(
            path: "/api/v1/assistant-commands", queryItems: []))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let remote = try JSONDecoder().decode(RemoteCommandCatalog.self, from: data)
            guard let targets = RemoteCommandCatalog.map(remote), !targets.isEmpty else {
                throw URLError(.cannotDecodeContentData)
            }
            return (data, targets)
        } catch {
            guard let host = endpoint.baseURL.host else { throw error }
            return try await fetch(host: host)
        }
    }

    func fetch(host: String) async throws -> (raw: Data, targets: [MentionTarget]) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = 42830
        components.path = "/commands.json"
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        // Intentionally no Authorization header.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let remote = try JSONDecoder().decode(RemoteCommandCatalog.self, from: data)
        guard let targets = RemoteCommandCatalog.map(remote), !targets.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
        return (data, targets)
    }
}

@MainActor @Observable
final class CommandCatalogStore {
    private(set) var targets: [MentionTarget]
    private let provider: any CommandCatalogProvider
    private let fetcher: RemoteCommandCatalogFetcher
    private var lastFetch: Date?
    private var isFetching = false

    private static let logger = Logger(subsystem: "com.ferry.test", category: "CommandCatalog")
    private static let throttle: TimeInterval = 60

    init(provider: any CommandCatalogProvider = LocalCommandCatalogProvider()) {
        self.provider = provider
        self.fetcher = RemoteCommandCatalogFetcher()
        self.targets = (try? provider.loadCatalog()) ?? []
    }

    /// The "@…" wake tag that addresses an assistant, e.g. "@总管".
    ///
    /// FerryHelper publishes it as the assistant group's "叫醒" pseudo-command
    /// (`insert_text`), so the phone uses exactly the string the desktop shows.
    /// Falls back to "@" + the assistant's name when the catalog has no entry
    /// (FerryHelper unreachable, or a locally created assistant) — which is the
    /// same shape FerryHelper's own default config uses.
    func wakeTag(forAssistantName name: String) -> String {
        // FerryHelper's built-in command interpreter explicitly recognizes
        // @助手, not @助理 or @FerryHelper.
        if name == "助手" || name == "助理" || name == "FerryHelper" {
            return "@助手"
        }
        if let target = targets.first(where: { $0.matchesAssistant(name) }),
           let tag = Self.extractedWakeTag(from: target.insertText) {
            return tag
        }
        return "@" + name
    }

    /// Extracts a leading "@tag" from a catalog `insert_text` ("@总管 ").
    private static func extractedWakeTag(from insertText: String?) -> String? {
        guard let text = insertText?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("@"), text.count > 1 else { return nil }
        return text
    }

    /// Fetch the FerryHelper catalog for the configured server host (port 42830),
    /// throttled to once per 60 s. Failures are silent (os.Logger debug only,
    /// never a user-facing error or a secret) and leave the cached/built-in
    /// catalog in place.
    func refresh(endpoint: ServerEndpoint?, token: String?) {
        guard let endpoint, !isFetching else { return }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < Self.throttle { return }
        lastFetch = Date()
        isFetching = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isFetching = false }
            do {
                let (raw, targets) = try await self.fetcher.fetch(
                    endpoint: endpoint, token: token)
                Self.saveRaw(raw)
                self.targets = targets
            } catch {
                Self.logger.debug("command catalog fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func saveRaw(_ data: Data) {
        guard let url = LocalCommandCatalogProvider.catalogURL else { return }
        try? data.write(to: url, options: .atomic)
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
        return targets.filter { $0.matches(q) }
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
                    if let subtitle = target.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    } else if let alias = target.alias {
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


// MARK: - Dedicated computer task UI

/// The Windows FerryHelper owns the command vocabulary. This panel displays
/// only commands supplied by its catalog (including the existing cached copy),
/// rather than inventing HTTP endpoints or unsupported command spellings.
struct AssistantTaskPanel: View {
    @Bindable var model: AppModel

    @State private var chosenID: String?
    @State private var showTaskSheet = false
    @State private var argument = ""
    @State private var includeDate = false
    @State private var date = Date()
    @State private var executing = false

    private var target: MentionTarget? {
        model.catalog.targets.first {
            $0.id == "助手" || $0.id == "helper" ||
            $0.matchesAssistant("助手") || $0.matchesAssistant("FerryHelper")
        }
    }

    private var commands: [CommandItem] {
        guard let target else { return [] }
        if !target.commands.isEmpty { return target.commands }
        // Remote catalogs may publish a helper group with a single command.
        if let insert = target.insertText, !insert.isEmpty {
            return [CommandItem(id: target.id, title: target.title, insertText: insert,
                                subtitle: target.subtitle)]
        }
        return []
    }

    private var chosen: CommandItem? {
        commands.first(where: { $0.id == chosenID })
    }

    /// Date choice is an optional, editable positional argument. Never
    /// synthesize flags that are not declared by the Windows command catalog.
    private var offersDate: Bool {
        guard let chosen else { return false }
        // Only /找 accepts a standalone date; /发文件 expects a filename.
        return chosen.insertText.trimmingCharacters(in: .whitespaces).hasPrefix("/找")
    }

    private var preparedText: String? {
        guard let chosen else { return nil }
        let verb = chosen.insertText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !verb.isEmpty else { return nil }
        var text = verb.hasPrefix("@") || model.routeIsolationEnabled
            ? verb : model.catalog.wakeTag(forAssistantName: "助手") + " " + verb
        let arguments = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if chosen.requiresArgument && arguments.isEmpty && !includeDate { return nil }
        if !arguments.isEmpty { text += " " + arguments }
        if includeDate && offersDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            text += " " + formatter.string(from: date)
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.cyan)
                Text("电脑助手")
                    .font(.subheadline.weight(.semibold))
                Text("快捷命令")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshCommandCatalog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新电脑命令")
            }
            if commands.isEmpty {
                Text("暂无可用命令，点击右侧刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(commands) { command in
                            Button {
                                chosenID = command.id
                                argument = ""
                                includeDate = false
                                showTaskSheet = true
                            } label: {
                                Text(command.title)
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 13)
                                    .frame(height: 36)
                                    .background(Color.white.opacity(0.10),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("helper-command-\(command.id)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("computer-assistant-commands")
        .sheet(isPresented: $showTaskSheet) {
            taskEditor
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var taskEditor: some View {
        NavigationStack {
            Form {
                if let chosen {
                    Section {
                        if let subtitle = chosen.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if chosen.requiresArgument || offersDate {
                            TextField(chosen.requiresArgument ? "输入所需参数" : "附加参数（可选）",
                                      text: $argument)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        if offersDate {
                            Toggle("指定日期", isOn: $includeDate)
                            if includeDate {
                                DatePicker("日期", selection: $date,
                                           displayedComponents: .date)
                                    .datePickerStyle(.compact)
                            }
                        }
                    } header: {
                        Text("命令参数")
                    }
                    Section {
                        Button("填入聊天输入框") {
                            guard let preparedText else { return }
                            model.draft = preparedText
                            showTaskSheet = false
                        }
                        .disabled(preparedText == nil)

                        Button {
                            guard let preparedText, !executing else { return }
                            executing = true
                            Task { @MainActor in
                                let success = await model.sendText(preparedText)
                                executing = false
                                if success {
                                    chosenID = nil
                                    argument = ""
                                    includeDate = false
                                    showTaskSheet = false
                                    model.requestScrollToBottom()
                                }
                            }
                        } label: {
                            if executing {
                                HStack {
                                    ProgressView()
                                    Text("正在执行…")
                                }
                            } else {
                                Label("执行任务", systemImage: "paperplane.fill")
                            }
                        }
                        .disabled(preparedText == nil || executing)
                    }
                }
            }
            .navigationTitle(chosen?.title ?? "电脑助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showTaskSheet = false }
                }
            }
        }
    }
}
