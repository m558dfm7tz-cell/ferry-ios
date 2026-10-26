import SwiftUI

// MARK: - Metrics

enum ReviewEntryMetrics {
    /// Vertical space the pinned 待查看 row takes under the avatar bar. The
    /// timeline reserves exactly this much so the transcript still scrolls
    /// under the row instead of being hidden by it.
    static let height: CGFloat = 56
}

// MARK: - Pinned entry

/// The fixed 待查看（N）row at the top of the 总管 page. Hidden entirely when
/// nothing is unread, so the page is unchanged in the common case.
struct ReviewEntryRow: View {
    let count: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 30, height: 30)
                    .background(Color.orange.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("待查看（\(count)）")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("总管等你过目")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: ReviewEntryMetrics.height - 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("待查看 \(count) 条")
        .accessibilityIdentifier("review-entry")
    }
}

// MARK: - List

/// The standalone 待查看 list opened from the pinned row: every item 总管 has
/// sent (newest first), each tappable into its detail page. Items already
/// marked 已看 stay in the list so they can be re-read.
struct ReviewListView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.reviewStore.items.isEmpty {
                    ContentUnavailableView(
                        "暂无待查看内容", systemImage: "tray",
                        description: Text("总管发来带「待查看」标记的消息后，会出现在这里。"))
                } else {
                    List {
                        ForEach(model.reviewStore.items) { item in
                            NavigationLink {
                                ReviewDetailView(model: model, item: item)
                            } label: {
                                ReviewItemRow(item: item, seen: model.reviewStore.isSeen(item.id))
                            }
                            .accessibilityIdentifier("review-row-\(item.id)")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("待查看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("review-close")
                }
            }
        }
    }
}

/// One row: type badge, title, 说明 and time, with an orange dot while unread.
private struct ReviewItemRow: View {
    let item: ReviewItem
    let seen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.kind.tint)
                .frame(width: 28, height: 28)
                .background(item.kind.tint.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(seen ? Color.secondary : Color.primary)
                        .lineLimit(2)
                    if !seen {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .padding(.top, 2)
                    }
                }
                Text(item.displaySummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(item.kind.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.kind.tint)
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text(item.listTimeText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

/// Full item: type, title, time, 说明 and 详情, with 标为已看 and 回复 at the
/// bottom. 回复 sends an ordinary message quoting this item (see
/// `ReviewReplyFormatter`).
struct ReviewDetailView: View {
    @Bindable var model: AppModel
    let item: ReviewItem

    @State private var showReply = false
    @State private var replyText = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private var seen: Bool { model.reviewStore.isSeen(item.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Text(item.title)
                    .font(.title3.weight(.semibold))
                Text(item.listTimeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider().padding(.vertical, 2)
                block(title: "说明", text: item.displaySummary)
                if let detail = item.detail, !detail.isEmpty {
                    block(title: "详情", text: detail)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .background(Color.chatBackground.ignoresSafeArea())
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { actionBar }
        .sheet(isPresented: $showReply) { replySheet }
        .alert("回复失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .accessibilityIdentifier("review-detail")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.kind.tint)
            Text(item.kind.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(item.kind.tint)
            Spacer(minLength: 8)
            if seen {
                Text("已看")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(.systemGray5), in: Capsule())
            }
        }
    }

    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                model.reviewStore.markSeen(item.id)
            } label: {
                Label(seen ? "已看" : "标为已看",
                      systemImage: seen ? "checkmark.circle.fill" : "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(seen)
            .accessibilityIdentifier("review-mark-seen")

            Button { showReply = true } label: {
                Label("回复", systemImage: "arrowshape.turn.up.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("review-reply")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Reply

    private var replySheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                quotedCard
                TextEditor(text: $replyText)
                    .frame(minHeight: 140)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color(.separator), lineWidth: 1)
                    }
                    .accessibilityIdentifier("review-reply-input")
                Text("发送后会出现在总管那边的普通消息里，并引用这条待查看。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("回复总管")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showReply = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        isSending = true
                        Task { await sendReply() }
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    .accessibilityIdentifier("review-reply-send")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var quotedCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(item.kind.tint)
                Text(item.kind.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.kind.tint)
            }
            Text(item.title)
                .font(.subheadline.weight(.semibold))
            Text(item.displaySummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.incomingBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func sendReply() async {
        let text = replyText
        defer { isSending = false }
        if await model.sendReviewReply(text, for: item) {
            showReply = false
            replyText = ""
        } else {
            errorMessage = "发送失败，请检查连接后重试。"
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
