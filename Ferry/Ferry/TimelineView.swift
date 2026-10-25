import SwiftUI

struct TimelineView: View {
    @Bindable var model: AppModel
    @FocusState private var composerFocused: Bool
    @State private var showImageGrid = false
    @State private var showFavorites = false
    @State private var atBottom = true
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var selectionAlert: SelectionAlert?

    private enum SelectionAlert: String, Identifiable {
        case delete, clearAll
        var id: String { rawValue }
        var title: String {
            switch self {
            case .delete: return "删除消息"
            case .clearAll: return "清空全部"
            }
        }
    }

    private var selectionAlertBinding: Binding<Bool> {
        Binding(get: { selectionAlert != nil }, set: { if !$0 { selectionAlert = nil } })
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if model.messages.isEmpty {
                            ContentUnavailableView("等待传输", systemImage: "shippingbox",
                                                   description: Text("来自电脑的消息和文件会显示在这里。"))
                                .padding(.top, 100)
                        }
                        ForEach(model.daySections) { section in
                            Text(section.dayLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                            ForEach(section.messages) { message in
                                MessageRow(message: message,
                                           image: model.images[message.id],
                                           videoThumbnail: model.videoThumbnails[message.id],
                                           loadImage: { await model.loadImage(for: message) },
                                           loadVideoThumbnail: { await model.loadVideoThumbnail(for: message) },
                                           loadFile: { await model.fileData(for: message) },
                                           isCurrent: message.isCurrentDevice,
                                           isFavorite: model.localStore.isFavorite(message.id),
                                           onToggleFavorite: { await model.toggleFavorite(message) },
                                           selectionMode: selectionMode,
                                           isSelected: selectedIDs.contains(message.id),
                                           onToggleSelection: { toggleSelection(message.id) })
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 20)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let id = model.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
                } action: { _, newValue in
                    atBottom = newValue
                }
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                .scrollContentBackground(.hidden)
                .background(Color.chatBackground.ignoresSafeArea())
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button {
                            if let id = model.messages.last?.id {
                                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        } label: {
                            Label("最新消息", systemImage: "arrow.down")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.black.opacity(0.72), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16).padding(.bottom, 12)
                        .transition(.opacity)
                    }
                }
            }
            .navigationTitle("Ferry")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectionMode {
                        Button("取消") { exitSelection() }
                    } else {
                        Label(model.currentDevice?.name ?? "设备", systemImage: "iphone")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("current-device")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selectionMode {
                        HStack(spacing: 16) {
                            Button { showFavorites = true } label: { Image(systemName: "star") }
                                .accessibilityLabel("收藏")
                            Button { showImageGrid = true } label: { Image(systemName: "square.grid.2x2") }
                                .accessibilityLabel("图片")
                            Button { enterSelection() } label: { Text("选择") }
                                .accessibilityLabel("选择")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selectionMode {
                    SelectionBar(selectedCount: selectedIDs.count,
                                 onDelete: { selectionAlert = .delete },
                                 onClearAll: { selectionAlert = .clearAll })
                } else {
                    ComposerView(model: model, focused: $composerFocused)
                }
            }
        }
        .sheet(isPresented: $showImageGrid) {
            ImageGridView(messages: model.imageMessages,
                          images: model.images,
                          loadImage: { m in await model.loadImage(for: m) },
                          loadFile: { m in await model.fileData(for: m) })
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView(model: model)
        }
        .alert(selectionAlert?.title ?? "", isPresented: selectionAlertBinding, presenting: selectionAlert) { alert in
            switch alert {
            case .delete:
                Button("删除", role: .destructive) {
                    model.deleteSelected(selectedIDs)
                    exitSelection()
                }
                Button("取消", role: .cancel) {}
            case .clearAll:
                Button("清空全部", role: .destructive) {
                    model.clearAllMessages()
                    exitSelection()
                }
                Button("取消", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .delete:
                Text("确定从本机删除选中的 \(selectedIDs.count) 条消息吗？其他设备仍会保留这些消息。")
            case .clearAll:
                Text("确定清空本机全部消息吗？此操作仅在本机隐藏，不会删除服务器上的消息。")
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func enterSelection() {
        selectedIDs = []
        selectionMode = true
    }

    private func exitSelection() {
        selectionMode = false
        selectedIDs = []
    }
}

/// Bottom bar shown while in select mode: 清空全部 on the left, 删除(N) on the
/// right. Confirmation happens in the parent via alerts.
private struct SelectionBar: View {
    let selectedCount: Int
    let onDelete: () -> Void
    let onClearAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("清空全部", systemImage: "trash") { onClearAll() }
                .buttonStyle(.bordered)
                .tint(.red)
            Spacer()
            Button {
                onDelete()
            } label: {
                Text(selectedCount > 0 ? "删除(\(selectedCount))" : "删除")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}
