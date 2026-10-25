import SwiftUI

struct TimelineView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        if model.messages.isEmpty {
                            ContentUnavailableView("Ready to ferry", systemImage: "shippingbox",
                                                   description: Text("Messages and files from your PC appear here."))
                                .padding(.top, 100)
                        }
                        ForEach(model.messages) { message in
                            MessageRow(message: message, image: model.images[message.id],
                                       loadImage: { await model.loadImage(for: message) },
                                       loadFile: { await model.fileData(for: message) })
                                .id(message.id)
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 20)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let id = model.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            .navigationTitle("Ferry")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Label(model.currentDevice?.name ?? "Device", systemImage: "iphone")
                        .font(.subheadline.weight(.semibold)).accessibilityIdentifier("current-device")
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let warning = model.credentialWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
            if let message = model.statusMessage {
                Label(message, systemImage: model.phase == .offline ? "wifi.exclamationmark" : "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(model.phase == .offline ? .orange : .red)
            }
            if model.phase == .offline {
                Button("Change Server", systemImage: "network") { model.disconnect() }
                    .buttonStyle(.bordered).accessibilityIdentifier("change-server")
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5).padding(.horizontal, 4).padding(.vertical, 10)
                    .accessibilityIdentifier("message-input")
                Button("Send", systemImage: "arrow.up") { Task { await model.send() } }
                    .labelStyle(.iconOnly).buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canSend).accessibilityIdentifier("send-message")
            }
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}
