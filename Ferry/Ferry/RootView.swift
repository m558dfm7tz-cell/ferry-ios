import SwiftUI
import UIKit

struct RootView: View {
    @Bindable var model: AppModel
    @State private var sharedBatch: FerrySharedBatch?
    @State private var shareRecipient: String?
    @State private var shareError: String?
    @State private var sharingNow = false
    @State private var checkingSharedRoute = false
    @State private var importingNow = false
    @State private var importError: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(uiColor: .systemBackground), Color.accentColor.opacity(0.08)],
                           startPoint: .top, endPoint: .bottomTrailing).ignoresSafeArea()
            if model.phase == .setup || model.phase == .connecting { AccessView(model: model) }
            else { TimelineView(model: model) }
        }
        .task {
            await model.start()
            await importSystemInbox()
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task {
                // Open In may have already copied into Documents/Inbox.
                // Use the same single importer as the foreground scan.
                if url.path.contains("/Documents/Inbox/") {
                    await importSystemInbox()
                } else {
                    await importExternalFile(url)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                await importSystemInbox()
                // After updating Go/FerryHelper on Windows, the previously
                // paired phone may return to Ferry without logging in again.
                // Recheck runtime transfer capability on foreground so the
                // 互传 composer can recover as soon as the correct Helper
                // connects, without weakening the server route guard.
                if model.phase == .connected {
                    _ = await model.retryVerifiedRouting()
                }
            }
        }
        .onChange(of: model.phase == .connected) { _, active in
            if active { discoverIncomingShare() }
        }
        .alert("文件导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(item: $sharedBatch, onDismiss: {
            shareRecipient = nil
            shareError = nil
        }) { batch in
            incomingShareSheet(batch)
                .interactiveDismissDisabled(sharingNow)
        }
    }

    private func discoverIncomingShare() {
        guard model.phase == .connected, sharedBatch == nil else { return }
        sharedBatch = FerryShareInbox.readPending()
        shareRecipient = nil
        shareError = nil
    }

    private func importSystemInbox() async {
        guard !importingNow else { return }
        importingNow = true
        defer { importingNow = false }
        await Task.detached(priority: .userInitiated) {
            FerryShareInbox.collectSystemInbox()
        }.value
        discoverIncomingShare()
    }

    private func importExternalFile(_ url: URL) async {
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try FerryShareInbox.importDocument(url)
            }.value
            if imported { discoverIncomingShare() }
        } catch {
            importError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func incomingShareSheet(_ batch: FerrySharedBatch) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("从其他 App 导入的文件", systemImage: "square.and.arrow.down")
                        .font(.headline)
                    Text("此文件通过 iOS「用 Ferry 打开」导入。请选择对话并确认发送；关闭窗口仍会保留待发送文件。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(batch.entries) { entry in
                        Label(entry.name, systemImage: entry.kind == .text ? "text.alignleft" : "doc")
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                    Divider()
                    Text("发送到").font(.headline)
                    if model.routeIsolationEnabled {
                        if model.transferRouteAvailable {
                            shareDestinationRow(title: "互传", subtitle: "仅发送到 Windows／iPhone 互传",
                                                id: "__transfer__")
                        } else {
                            Label("互传暂不可用：当前 Go 未确认已连接具备路由保护的 FerryHelper。助手对话仍可单独发送。",
                                  systemImage: "exclamationmark.shield")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        ForEach(model.assistantStore.assistants) { assistant in
                            shareDestinationRow(title: assistant.name,
                                                subtitle: "独立助手对话", id: assistant.id)
                        }
                        routingRecheckControl
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("当前服务器尚未确认支持独立消息路由。为防止误发，暂不能发送外部分享。",
                                  systemImage: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                            Text("连接的 Go 服务器：\(model.endpoint?.origin ?? model.serverAddress)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("如果服务器支持独立助手路由，即使 Helper 离线也可以发送到已验证的助手；纯互传仍要求 Helper 在线。文件会继续保留。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await verifySharedRoute() }
                            } label: {
                                if checkingSharedRoute {
                                    ProgressView()
                                } else {
                                    Label("重新检测服务器支持", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(checkingSharedRoute)
                        }
                    }
                    if let shareError {
                        Text(shareError).font(.footnote).foregroundStyle(.red)
                    }
                    Button {
                        Task { await confirmSharedItems(batch) }
                    } label: {
                        if sharingNow { ProgressView() }
                        else { Text("确认发送到所选对话") }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(sharingNow || shareRecipient == nil ||
                              model.destinationForExternalShare(
                                shareRecipient == "__transfer__" ? nil : shareRecipient) == nil)
                }
                .padding(20)
            }
            .background(Color.chatBackground.ignoresSafeArea())
            .navigationTitle("分享至 Ferry")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await verifySharedRoute()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后") { sharedBatch = nil }
                        .disabled(sharingNow)
                }
            }
        }
    }

    @MainActor
    private func verifySharedRoute() async {
        guard !checkingSharedRoute else { return }
        checkingSharedRoute = true
        defer { checkingSharedRoute = false }
        let supported = await model.retryVerifiedRouting()
        if supported {
            shareError = nil
        } else {
            shareError = "服务器能力检查未通过。请确认此服务器上的 Go V2 与 FerryHelper 已配对并正常监听。"
        }
    }

    private var routingRecheckControl: some View {
        HStack {
            Text("Go：\(model.endpoint?.origin ?? model.serverAddress)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await verifySharedRoute() }
            } label: {
                if checkingSharedRoute { ProgressView() }
                else { Label("重新检测", systemImage: "arrow.clockwise") }
            }
            .buttonStyle(.bordered)
            .disabled(checkingSharedRoute)
        }
    }

    private func shareDestinationRow(title: String, subtitle: String, id: String) -> some View {
        Button { shareRecipient = id; shareError = nil } label: {
            HStack(spacing: 12) {
                Image(systemName: shareRecipient == id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(shareRecipient == id ? Color.cyan : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func confirmSharedItems(_ batch: FerrySharedBatch) async {
        guard let selected = shareRecipient,
              let destination = model.destinationForExternalShare(
                selected == "__transfer__" ? nil : selected) else {
            shareError = "请先选择已验证的目标对话。"
            return
        }
        sharingNow = true
        defer { sharingNow = false }
        var remaining = batch
        for entry in batch.entries {
            if entry.kind == .text {
                guard let text = entry.text,
                      await model.sendText(text, destinationOverride: destination) else {
                    shareError = "发送文字失败。已发送的条目不会重复发送。"
                    return
                }
            } else {
                guard let url = FerryShareInbox.fileURL(batch: batch, entry: entry) else {
                    shareError = "分享文件已不存在，请重新从原 App 分享。"
                    return
                }
                if let error = model.uploader.enqueue(fileURL: url, name: entry.name,
                                                       mediaType: entry.mediaType,
                                                       destinationOverride: destination) {
                    shareError = error
                    return
                }
            }
            FerryShareInbox.markQueued(entry, from: &remaining)
        }
        FerryShareInbox.remove(batch)
        sharedBatch = nil
        // Do not navigate or change the user's currently selected conversation.
        // The upload queue has already captured the explicit route for each item.
    }
}

private struct AccessView: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Field?
    @State private var showingScanner = false
    private enum Field: Hashable { case server, name, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                Image("PlaneLogo")
                    .resizable().scaledToFit()
                    .padding(18)
                    .frame(width: 92, height: 92)
                    .background(Color(red: 0.06, green: 0.09, blue: 0.16), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Ferry").font(.largeTitle.bold())
                    Text("在你的设备之间传输文字、文件和照片。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                VStack(spacing: 16) {
                    VStack(spacing: 16) {
                        TextField("服务器地址", text: $model.serverAddress)
                            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().focused($focused, equals: .server)
                            .accessibilityIdentifier("server-address")
                        TextField("设备名称", text: $model.deviceName)
                            .focused($focused, equals: .name).accessibilityIdentifier("device-name")
                        SecureField("访问密码（如已启用）", text: $model.accessPassword)
                            .textContentType(.password)
                            .focused($focused, equals: .password).accessibilityIdentifier("access-password")
                        if let message = model.statusMessage {
                            Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("access-error")
                        }
                        Button { focused = nil; Task { await model.connect() } } label: {
                            HStack { if model.phase == .connecting { ProgressView() }; Text("连接").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.phase == .connecting)
                        .accessibilityIdentifier("connect-device")
                    }
                    .padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                    if !model.savedComputers.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("已保存的电脑").font(.headline)
                            ForEach(model.savedComputers) { computer in
                                Button {
                                    focused = nil
                                    Task { await model.switchComputer(origin: computer.origin) }
                                } label: {
                                    HStack {
                                        Image(systemName: "desktopcomputer")
                                        VStack(alignment: .leading) {
                                            Text(computer.name).font(.body.weight(.medium))
                                            Text(computer.origin).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.footnote)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    discovery
                }
            }
            .padding(.horizontal, 24)
        }
        .fullScreenCover(isPresented: $showingScanner) {
            QRScannerView(onScan: { text in
                showingScanner = false
                model.applyScannedAddress(text)
            }, onCancel: { showingScanner = false })
        }
    }

    private var discovery: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.discover() }
            } label: {
                HStack {
                    if model.isDiscovering { ProgressView() }
                    else { Image(systemName: "dot.radiowaves.left.and.right") }
                    Text(model.isDiscovering ? "正在扫描…" : "在网络中查找电脑")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(model.isDiscovering)
            .accessibilityIdentifier("find-pc")

            Button {
                showingScanner = true
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                    Text("扫描二维码连接")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)

            if let message = model.discoveryMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.discovered.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.discovered) { server in
                        Button {
                            model.selectDiscovered(server)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundStyle(.cyan)
                                Text(server.origin).font(.subheadline.monospaced())
                                Spacer()
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("discovered-server")
                    }
                }
            } else if let last = model.lastServerOrigin {
                Button {
                    model.selectDiscovered(DiscoveredServer(origin: last))
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上次连接的地址").font(.caption).foregroundStyle(.secondary)
                            Text(last).font(.subheadline.monospaced())
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
