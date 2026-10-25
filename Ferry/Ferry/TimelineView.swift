import SwiftUI

struct TimelineView: View {
    @Bindable var model: AppModel
    @FocusState private var composerFocused: Bool
    @State private var showImageGrid = false
    @State private var atBottom = true

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
                                           loadImage: { await model.loadImage(for: message) },
                                           loadFile: { await model.fileData(for: message) },
                                           isCurrent: message.isCurrentDevice)
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
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Label(model.currentDevice?.name ?? "设备", systemImage: "iphone")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("current-device")
                        Button {
                            showImageGrid = true
                        } label: {
                            Image(systemName: "square.grid.2x2")
                        }
                        .accessibilityLabel("图片")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { ComposerView(model: model, focused: $composerFocused) }
        }
        .sheet(isPresented: $showImageGrid) {
            ImageGridView(messages: model.imageMessages,
                          images: model.images,
                          loadImage: { m in await model.loadImage(for: m) },
                          loadFile: { m in await model.fileData(for: m) })
        }
    }
}
