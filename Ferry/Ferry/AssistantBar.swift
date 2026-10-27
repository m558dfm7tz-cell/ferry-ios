import Foundation
import Observation
import SwiftUI

// MARK: - Model

/// A chat assistant shown in the top avatar bar. Built-in assistants are fixed;
/// custom ones are created via "＋新建" and persisted locally.
struct Assistant: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let avatarText: String
    let colorIndex: Int
    let isBuiltIn: Bool
    let matchKeywords: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, avatarText, colorIndex, isBuiltIn, matchKeywords
    }

    init(id: String, name: String, avatarText: String, colorIndex: Int,
         isBuiltIn: Bool, matchKeywords: [String]) {
        self.id = id
        self.name = name
        self.avatarText = avatarText
        self.colorIndex = colorIndex
        self.isBuiltIn = isBuiltIn
        self.matchKeywords = matchKeywords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatarText = try c.decodeIfPresent(String.self, forKey: .avatarText) ?? ""
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        matchKeywords = try c.decodeIfPresent([String].self, forKey: .matchKeywords) ?? []
    }

    var color: Color { AssistantPalette.color(at: colorIndex) }

    /// Whether a message whose sender device name is `senderName` belongs to
    /// this assistant. Follows the web (W2) rule: the sender name contains one
    /// of the keywords (case-insensitive for Latin, literal for Chinese).
    func matches(senderName: String) -> Bool {
        matchKeywords.contains { senderName.localizedCaseInsensitiveContains($0) }
    }
}

// MARK: - Color palette

enum AssistantPalette {
    /// Dark-friendly, high-saturation disc colors. Order is stable (append-only)
    /// so a persisted `colorIndex` keeps meaning across versions.
    static let colors: [Color] = [
        Color(red: 0.30, green: 0.55, blue: 0.95), // blue
        Color(red: 0.61, green: 0.35, blue: 0.90), // purple
        Color(red: 0.93, green: 0.42, blue: 0.55), // pink
        Color(red: 0.95, green: 0.60, blue: 0.25), // orange
        Color(red: 0.30, green: 0.72, blue: 0.50), // green
        Color(red: 0.25, green: 0.72, blue: 0.72), // teal
        Color(red: 0.45, green: 0.45, blue: 0.85), // indigo
        Color(red: 0.90, green: 0.35, blue: 0.35), // red
    ]

    static func color(at index: Int) -> Color {
        guard !colors.isEmpty else { return .gray }
        let i = index % colors.count
        return colors[i >= 0 ? i : i + colors.count]
    }
}

// MARK: - Store

@MainActor @Observable
final class AssistantStore {
    private(set) var custom: [Assistant]
    private let defaults: UserDefaults
    private(set) var spaceKey: SpaceKey?
    private static let customKey = "ferry.local.customAssistants"

    private var scopedKey: String { Self.customKey + "." + (spaceKey?.value ?? "") }

    /// Fixed assistants and their sender-name match keywords.
    static let builtIn: [Assistant] = [
        Assistant(id: "chief", name: "总管", avatarText: "总", colorIndex: 3, isBuiltIn: true,
                  matchKeywords: ["总管"]),
        Assistant(id: "workbuddy", name: "WorkBuddy", avatarText: "W", colorIndex: 0, isBuiltIn: true,
                  matchKeywords: ["workbuddy"]),
        Assistant(id: "intel", name: "情报员", avatarText: "情", colorIndex: 4, isBuiltIn: true,
                  matchKeywords: ["情报员"]),
        Assistant(id: "muse", name: "muse联络员", avatarText: "M", colorIndex: 1, isBuiltIn: true,
                  matchKeywords: ["muse"]),
        Assistant(id: "helper", name: "助理", avatarText: "助", colorIndex: 2, isBuiltIn: true,
                  matchKeywords: ["FerryHelper", "助理"]),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.custom = []
    }

    /// Point the store at one Ferry space and load its custom assistants. The
    /// first space ever activated absorbs legacy (unscoped) data.
    func activate(space: SpaceKey) {
        guard space != spaceKey else { return }
        spaceKey = space
        if let data = defaults.data(forKey: scopedKey),
           let decoded = try? JSONDecoder().decode([Assistant].self, from: data) {
            custom = decoded
        } else if let legacy = defaults.data(forKey: Self.customKey),
                  let decoded = try? JSONDecoder().decode([Assistant].self, from: legacy) {
            custom = decoded
            defaults.removeObject(forKey: Self.customKey)
            persist()
        } else {
            custom = []
        }
    }

    /// All assistants: fixed first, then custom.
    var assistants: [Assistant] { Self.builtIn + custom }

    /// Resolve the assistant a message belongs to.
    ///
    /// 1. An incoming message belongs to the assistant whose keywords match the
    ///    sender's device name (the web rule).
    /// 2. A message this phone sent belongs to the assistant it *addresses*:
    ///    the body starts with that assistant's wake tag ("@总管 …"). Same rule
    ///    as the web timeline's `mentionTargetAssistant()`, so a reply sent
    ///    from an assistant page groups identically on every device.
    ///
    /// Own messages without a tag stay unattributed: they keep the plain
    /// right-aligned layout and are only listed under 全部.
    func assistant(for message: MessagePayload) -> Assistant? {
        guard message.isCurrentDevice else { return matchingAssistant(senderName: message.senderName) }
        return mentionedAssistant(inMessage: message)
    }

    /// The assistant a leading "@name" in a text body points at, or nil when
    /// there is no such mention. Only text messages participate — a file
    /// message has no body that could carry a tag.
    func mentionedAssistant(inMessage message: MessagePayload) -> Assistant? {
        guard message.kind == .text, let text = message.text else { return nil }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // FerryHelper normalises the full-width ＠ to "@"; match that here so
        // both spellings group the same way.
        if body.hasPrefix("＠") { body = "@" + String(body.dropFirst()) }
        guard body.hasPrefix("@") else { return nil }
        let name = body.dropFirst().prefix { !Self.mentionTerminators.contains($0) }
        guard !name.isEmpty else { return nil }
        return assistant(named: String(name))
    }

    /// Characters that end an "@name" mention: whitespace plus the punctuation
    /// the web timeline stops at, so "@总管，帮我" still reads as 总管.
    private static let mentionTerminators: Set<Character> = [
        " ", "\t", "\n", "\r", "@", "＠",
        "，", "。", "、", "！", "？", "：", "；", ",", ".", "!", "?", ":", ";"
    ]

    /// Exact (case-insensitive) lookup by assistant name.
    func assistant(named name: String) -> Assistant? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return assistants.first {
            $0.name.localizedCaseInsensitiveCompare(target) == .orderedSame ||
            ($0.id == "helper" && $0.matchKeywords.contains {
                $0.localizedCaseInsensitiveCompare(target) == .orderedSame
            })
        }
    }

    func matchingAssistant(senderName: String) -> Assistant? {
        let trimmed = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return assistants.first { $0.matches(senderName: trimmed) }
    }

    @discardableResult
    func addCustom(name: String, avatarText: String, colorIndex: Int) -> Assistant {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let letter = Self.sanitizedAvatarText(avatarText, fallbackName: trimmedName)
        let assistant = Assistant(id: UUID().uuidString, name: trimmedName, avatarText: letter,
                                  colorIndex: colorIndex, isBuiltIn: false,
                                  matchKeywords: trimmedName.isEmpty ? [] : [trimmedName])
        custom.append(assistant)
        persist()
        return assistant
    }

    /// Apply edits made in the long-press menu (name / avatar letter / colour).
    /// Built-in assistants are ignored — only custom ones can be edited.
    func update(_ assistant: Assistant) {
        guard !assistant.isBuiltIn,
              let index = custom.firstIndex(where: { $0.id == assistant.id }) else { return }
        let trimmedName = assistant.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let letter = Self.sanitizedAvatarText(assistant.avatarText, fallbackName: trimmedName)
        custom[index] = Assistant(id: assistant.id, name: trimmedName, avatarText: letter,
                                  colorIndex: assistant.colorIndex, isBuiltIn: false,
                                  matchKeywords: [trimmedName])
        persist()
    }

    /// Drop a custom assistant. Messages are untouched: they simply fall back
    /// to 全部. Returns whether something was removed.
    @discardableResult
    func removeCustom(id: String) -> Bool {
        guard custom.contains(where: { $0.id == id }) else { return false }
        custom.removeAll { $0.id == id }
        persist()
        return true
    }

    /// Replace the whole custom list (server reconcile). Existing ids are kept
    /// where names match, so avatar media / unread state stay attached.
    func replaceCustom(with assistants: [Assistant]) {
        custom = assistants
        persist()
    }

    private static func sanitizedAvatarText(_ text: String, fallbackName: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(1)) }
        if let first = fallbackName.first { return String(first) }
        return "?"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) {
            defaults.set(data, forKey: scopedKey)
        }
    }
}

// MARK: - Avatar view

/// Circular avatar reused by the bar, the message rows and the editor. Renders
/// the default letter disc, or the assistant's custom image / muted looping
/// video when one has been picked.
struct AssistantAvatarView: View {
    let assistant: Assistant
    var size: CGFloat = 32
    /// Custom media (image or looping video) resolved from `AssistantAvatarStore`.
    var media: AssistantAvatarMedia? = nil

    var body: some View {
        ZStack {
            if let media, media.kind == .image,
               let url = media.imageURL,
               let image = AssistantAvatarStore.cachedImage(at: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let media, media.kind == .video, let url = media.videoURL {
                LoopingVideoView(url: url)
            } else {
                defaultDisc
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var defaultDisc: some View {
        Text(assistant.avatarText)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(assistant.color, in: Circle())
    }
}

// MARK: - Bar

/// Height the timeline reserves at its top so messages scroll *under* the
/// floating bar instead of being hidden by it.
enum AssistantBarMetrics {
    static let height: CGFloat = 82
}

/// The horizontal, scrollable row of avatar buttons floating over the top of the
/// timeline: 全部 + each assistant + "＋新建". There is no background, so the
/// chat transcript shows through underneath. The selected avatar lights up, the
/// red dot marks assistants with unseen messages, and a long-press opens the
/// avatar editor (image / muted looping video / default).
struct AssistantBarView: View {
    let assistants: [Assistant]
    @Binding var selectedID: String?
    let unreadIDs: Set<String>
    let avatarStore: AssistantAvatarStore
    let onSelect: (String?) -> Void
    let onAdd: () -> Void
    /// Save edits made to a custom assistant (name / avatar letter / colour).
    let onUpdate: (Assistant) -> Void
    /// Delete a custom assistant (confirmation happens here, before the call).
    let onDelete: (String) -> Void

    @State private var editingAssistant: Assistant?
    @State private var renamingAssistant: Assistant?
    @State private var pendingDelete: Assistant?
    @Environment(\.colorScheme) private var colorScheme

    private let avatarSize: CGFloat = 40

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                avatarButton(title: "全部", text: "全", color: Color(.systemGray),
                             id: nil, accessibilityID: "assistant-avatar-all")
                ForEach(assistants) { assistant in
                    avatarButton(title: assistant.name, text: assistant.avatarText,
                                 color: assistant.color, id: assistant.id,
                                 accessibilityID: "assistant-avatar-\(assistant.id)",
                                 assistant: assistant)
                }
                addButton
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .accessibilityIdentifier("assistant-bar")
        .sheet(item: $editingAssistant) { assistant in
            NavigationStack {
                AssistantAvatarEditorView(assistant: assistant, store: avatarStore)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { editingAssistant = nil }
                        }
                    }
            }
        }
        .sheet(item: $renamingAssistant) { assistant in
            NavigationStack {
                EditAssistantSheet(assistant: assistant,
                                   onSave: { edited in
                                       onUpdate(edited)
                                       renamingAssistant = nil
                                   },
                                   onCancel: { renamingAssistant = nil })
            }
        }
        .alert("删除助手", isPresented: deleteAlertBinding, presenting: pendingDelete) { assistant in
            Button("删除", role: .destructive) {
                let id = assistant.id
                pendingDelete = nil
                onDelete(id)
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { assistant in
            Text("确定删除「\(assistant.name)」吗？只删除这个助手分类，消息不会被删除，会回到“全部”里。")
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    private func avatarButton(title: String, text: String, color: Color,
                              id: String?, accessibilityID: String,
                              assistant: Assistant? = nil) -> some View {
        let selected = selectedID == id
        let unread = id.map { unreadIDs.contains($0) } ?? false
        return Button {
            onSelect(id)
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    avatarDisc(assistant: assistant, text: text, color: color, selected: selected)
                        .opacity(selected ? 1 : 0.92)
                    if unread {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 2))
                    }
                }
                assistantName(title, selected: selected)
            }
            .frame(width: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
        .contextMenu {
            if let assistant {
                Button {
                    editingAssistant = assistant
                } label: {
                    Label("更换头像", systemImage: "photo")
                }
                // Only custom assistants can be renamed or deleted; the four
                // built-in ones keep their existing single-item menu.
                if !assistant.isBuiltIn {
                    Button {
                        renamingAssistant = assistant
                    } label: {
                        Label("改名字", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDelete = assistant
                    } label: {
                        Label("删除助手", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// The name under the avatar. The bar has no background of its own — the
    /// transcript, its bubbles and its photos scroll right underneath — so the
    /// label carries its own contrast: a soft blurred wash behind it plus a halo
    /// around the glyphs. Both are the opposite brightness of the label itself
    /// (the label follows `.primary`/`.secondary`, i.e. light text in dark mode
    /// and dark text in light mode), which is what keeps it readable over any
    /// background. Dark mode gets the dark shadow/晕染.
    private func assistantName(_ title: String, selected: Bool) -> some View {
        let darkMode = colorScheme == .dark
        let wash = darkMode ? Color.black.opacity(0.5) : Color.white.opacity(0.72)
        let halo = darkMode ? Color.black.opacity(0.8) : Color.white.opacity(0.85)
        return Text(title)
            .font(.caption2)
            .foregroundStyle(selected ? .primary : .secondary)
            .lineLimit(1)
            .shadow(color: halo, radius: 3, x: 0, y: 1)
            .shadow(color: halo.opacity(0.7), radius: 7, x: 0, y: 0)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background {
                // 晕染: a blurred capsule that spreads past the glyphs.
                Capsule()
                    .fill(wash)
                    .blur(radius: 5)
            }
    }

    /// The avatar disc itself: custom image/video when set, otherwise the
    /// coloured letter disc. A soft shadow keeps it readable over the transcript
    /// now that the bar no longer has a background.
    private func avatarDisc(assistant: Assistant?, text: String, color: Color,
                            selected: Bool) -> some View {
        discContent(assistant: assistant, text: text, color: color)
            .frame(width: avatarSize, height: avatarSize)
            .overlay {
                if selected {
                    Circle().strokeBorder(Color.white, lineWidth: 2.5)
                }
            }
            .shadow(color: Color.black.opacity(0.45), radius: 4, x: 0, y: 1)
    }

    @ViewBuilder
    private func discContent(assistant: Assistant?, text: String, color: Color) -> some View {
        if let assistant, let media = avatarStore.media(for: assistant.id) {
            AssistantAvatarView(assistant: assistant, size: avatarSize, media: media)
        } else if let assistant {
            AssistantAvatarView(assistant: assistant, size: avatarSize)
        } else {
            Text(text)
                .font(.system(size: avatarSize * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: avatarSize, height: avatarSize)
                .background(color, in: Circle())
        }
    }

    private var addButton: some View {
        Button(action: onAdd) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(Color(.systemFill), in: Circle())
                Text("新建")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新建助手")
        .accessibilityIdentifier("assistant-add")
    }
}

// MARK: - New-assistant sheet

/// Sheet for "＋新建": name + avatar letter + color, with a live preview.
struct NewAssistantSheet: View {
    let onSave: (String, String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var avatarText = ""
    @State private var colorIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字", text: $name)
                        .accessibilityIdentifier("assistant-name")
                    TextField("头像字（1 个字或字母）", text: $avatarText)
                        .accessibilityIdentifier("assistant-avatar-text")
                } header: {
                    Text("助手信息")
                } footer: {
                    Text("消息按发送方设备名自动归类，名字将作为匹配关键字。")
                }

                Section("头像颜色") {
                    colorPicker
                }

                Section("预览") {
                    HStack {
                        Spacer()
                        AssistantAvatarView(assistant: previewAssistant, size: 44)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("新建助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name, avatarText, colorIndex)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewAssistant: Assistant {
        let letter: String
        let t = avatarText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            letter = String(t.prefix(1))
        } else if let first = trimmedName.first {
            letter = String(first)
        } else {
            letter = "?"
        }
        return Assistant(id: "preview", name: trimmedName.isEmpty ? "新助手" : trimmedName,
                         avatarText: letter, colorIndex: colorIndex,
                         isBuiltIn: false, matchKeywords: [])
    }

    private var colorPicker: some View {
        AssistantColorPicker(colorIndex: $colorIndex)
    }
}

/// Shared 4-column colour grid used by the new- and edit-assistant sheets.
private struct AssistantColorPicker: View {
    @Binding var colorIndex: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(Array(AssistantPalette.colors.enumerated()), id: \.offset) { index, color in
                Button {
                    colorIndex = index
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 40, height: 40)
                        .overlay {
                            if colorIndex == index {
                                Circle().strokeBorder(Color.primary, lineWidth: 3)
                            }
                        }
                        .overlay {
                            if colorIndex == index {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("颜色 \(index + 1)")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Edit-assistant sheet

/// Sheet opened from a custom assistant's long-press menu (改名字): rename it
/// and change its avatar letter / colour. Its avatar image or looping video is
/// changed from the 更换头像 item of the same menu.
struct EditAssistantSheet: View {
    let assistant: Assistant
    let onSave: (Assistant) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var avatarText: String
    @State private var colorIndex: Int

    init(assistant: Assistant, onSave: @escaping (Assistant) -> Void,
         onCancel: @escaping () -> Void) {
        self.assistant = assistant
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: assistant.name)
        _avatarText = State(initialValue: assistant.avatarText)
        _colorIndex = State(initialValue: assistant.colorIndex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字", text: $name)
                        .accessibilityIdentifier("assistant-edit-name")
                    TextField("头像字（1 个字或字母）", text: $avatarText)
                        .accessibilityIdentifier("assistant-edit-avatar-text")
                } header: {
                    Text("助手信息")
                } footer: {
                    Text("名字同时作为消息归类的匹配关键字。头像图片/视频请用长按菜单里的“更换头像”。")
                }

                Section("头像颜色") {
                    AssistantColorPicker(colorIndex: $colorIndex)
                }

                Section("预览") {
                    HStack {
                        Spacer()
                        AssistantAvatarView(assistant: previewAssistant, size: 44)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("编辑助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(edited) }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The edited copy handed back to the store (same id, so custom avatar
    /// media and everything else keyed by id stays attached).
    private var edited: Assistant {
        Assistant(id: assistant.id, name: trimmedName,
                  avatarText: avatarText.trimmingCharacters(in: .whitespacesAndNewlines),
                  colorIndex: colorIndex, isBuiltIn: assistant.isBuiltIn,
                  matchKeywords: [trimmedName])
    }

    private var previewAssistant: Assistant {
        let letter: String
        let t = avatarText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            letter = String(t.prefix(1))
        } else if let first = trimmedName.first {
            letter = String(first)
        } else {
            letter = "?"
        }
        return Assistant(id: assistant.id, name: trimmedName.isEmpty ? "新助手" : trimmedName,
                         avatarText: letter, colorIndex: colorIndex,
                         isBuiltIn: false, matchKeywords: [])
    }
}
