import SwiftUI

/// Type filter chips for chat search. The server has no search API, so search
/// runs client-side over loaded messages and pages older in the background.
enum SearchFilter: String, CaseIterable, Identifiable {
    case all, text, image, video, file, link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .image: return "图片"
        case .video: return "视频"
        case .file: return "文件"
        case .link: return "链接"
        }
    }

    /// Keyword (text body or file name, case-insensitive) must match, and the
    /// message must belong to the selected type.
    static func matches(_ message: MessagePayload, query: String, filter: SearchFilter) -> Bool {
        let text = message.text ?? ""
        let fileName = message.file?.name ?? ""
        let keywordHit = text.localizedCaseInsensitiveContains(query)
            || fileName.localizedCaseInsensitiveContains(query)
        guard keywordHit else { return false }

        switch filter {
        case .all: return true
        case .text: return message.text != nil
        case .image: return message.file?.mediaType.hasPrefix("image/") == true
        case .video: return PreviewRouter.isVideo(message.file?.mediaType ?? "", name: fileName)
        case .file:
            guard let file = message.file else { return false }
            return !PreviewRouter.isImage(file.mediaType) && !PreviewRouter.isVideo(file)
        case .link:
            return text.contains("http://") || text.contains("https://")
        }
    }
}

/// Client-side chat search: keyword over text body + file name, type filter
/// chips, progress + cancel while paging older history. Tapping a result
/// closes search and scrolls to (and highlights) that message.
struct SearchView: View {
    @Bindable var model: AppModel
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter: SearchFilter = .all
    @State private var results: [MessagePayload] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                filterChips
                resultList
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: filter) { _, _ in scheduleSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索消息或文件名", text: $query)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("search-field")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空")
            }
        }
        .padding(10)
        .background(Color(.systemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { chip in
                    Button { filter = chip } label: {
                        Text(chip.title)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(filter == chip ? Color.accentColor : Color(.systemFill),
                                        in: Capsule())
                            .foregroundStyle(filter == chip ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search-filter-\(chip.rawValue)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var resultList: some View {
        if isSearching && results.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在查找…").font(.footnote).foregroundStyle(.secondary)
                Button("取消") { cancelSearch() }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !query.isEmpty && results.isEmpty {
            ContentUnavailableView("无结果", systemImage: "magnifyingglass",
                                   description: Text("没有找到匹配的消息。"))
        } else {
            List(results) { message in
                SearchResultRow(message: message, query: query)
                    .contentShape(Rectangle())
                    .onTapGesture { select(message) }
            }
            .listStyle(.plain)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { @MainActor in
            let found = await model.searchMessages(query: q, filter: filter)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func select(_ message: MessagePayload) {
        searchTask?.cancel()
        dismiss()
        onSelect(message.id)
    }
}

private struct SearchResultRow: View {
    let message: MessagePayload
    let query: String

    var body: some View {
        HStack(spacing: 12) {
            if let file = message.file {
                FileTypeIconView(file: file)
            } else {
                Image(systemName: "text.bubble").foregroundStyle(.secondary).frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(TimestampFormat.dayLabel(from: message.createdAt) + " " + message.timeText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Short snippet: the matched text body, or the file name for files.
    private var snippet: String {
        if let text = message.text {
            return text
        }
        return message.file?.name ?? ""
    }
}
