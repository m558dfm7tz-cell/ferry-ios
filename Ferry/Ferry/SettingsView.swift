import SwiftUI

/// App settings: the video-send behavior toggle, the new-message notification
/// switch, and the device-management page.
/// By default videos are transcoded to MP4 before upload; enable "发送原始视频"
/// to send the original container unchanged.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ferry.sendOriginalVideo") private var sendOriginalVideo = false
    @Bindable private var notificationSettings = NotificationSettings.shared
    let model: AppModel
    @State private var editingOrigin: String?
    @State private var editedName = ""
    @State private var showingAddComputer = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("新消息通知", isOn: $notificationSettings.isEnabled)
                        .accessibilityIdentifier("notifications-toggle")
                } header: {
                    Text("通知")
                } footer: {
                    Text("开启后，App 在后台或不在当前会话时收到新消息会弹出通知，标题是发送方助手名，正文是消息摘要（图片/视频/文件会显示类型提示）。图标角标显示未读数，查看后自动清零。通知只由本机构造，不经过任何服务器。")
                }

                Section {
                    Toggle("发送视频时不转换格式", isOn: $sendOriginalVideo)
                    Text("关闭时，从相册或相机发送的视频会默认转码为 MP4（H.264/AAC），兼容性更好。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("视频发送")
                }

                Section {
                    ForEach(model.savedComputers) { computer in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(computer.name)
                                Text(computer.origin).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.endpoint?.origin == computer.origin {
                                Text("当前").foregroundStyle(.secondary).font(.caption)
                            } else {
                                Button("切换") {
                                    dismiss()
                                    Task { await model.switchComputer(origin: computer.origin) }
                                }
                            }
                            Button {
                                editedName = computer.name
                                editingOrigin = computer.origin
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { offsets in
                        let computers = model.savedComputers
                        for index in offsets { model.removeSavedComputer(origin: computers[index].origin) }
                    }
                    Button {
                        showingAddComputer = true
                    } label: {
                        Label("添加电脑", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("add-computer")
                    Text("选中哪台电脑，就使用哪台电脑的聊天和通知；新电脑可扫码、手动输入或局域网发现。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("已保存的电脑")
                }

                Section {
                    NavigationLink {
                        DeviceManagementView(model: model)
                    } label: {
                        Label("设备管理", systemImage: "iphone.gen3")
                    }
                    .accessibilityIdentifier("device-management-link")
                } header: {
                    Text("设备")
                }

                Section {
                    ForEach(model.assistantStore.assistants) { assistant in
                        NavigationLink {
                            AssistantAvatarEditorView(assistant: assistant, store: model.avatarStore)
                        } label: {
                            HStack(spacing: 10) {
                                AssistantAvatarView(assistant: assistant, size: 32,
                                                    media: model.avatarStore.media(for: assistant.id))
                                Text(assistant.name)
                            }
                        }
                        .accessibilityIdentifier("assistant-avatar-setting-\(assistant.id)")
                    }
                } header: {
                    Text("助手头像")
                } footer: {
                    Text("可设为图片或视频（视频静音循环播放）。头像保存在本机，暂未与服务器同步。")
                }
            }
            .alert("修改电脑名称", isPresented: Binding(
                get: { editingOrigin != nil },
                set: { if !$0 { editingOrigin = nil } }
            )) {
                TextField("电脑名称", text: $editedName)
                Button("保存") {
                    if let origin = editingOrigin { model.renameComputer(origin: origin, name: editedName) }
                    editingOrigin = nil
                }
                Button("取消", role: .cancel) { editingOrigin = nil }
            }
            .sheet(isPresented: $showingAddComputer) {
                AddComputerSheet(model: model) {
                    showingAddComputer = false
                    dismiss()
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .onChange(of: notificationSettings.isEnabled) { _, _ in
                model.notificationSettingsDidChange()
            }
        }
    }
}

    
/// Adds a server to the same saved-computer collection used by the switcher.
/// The existing model.connect() still owns credentials, per-server cache and
/// notification routing; no second server is polled in the background.
private struct AddComputerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let onConnected: () -> Void
    private enum Step { case choose, form, discover }
    @State private var step: Step = .choose
    @State private var showingScanner = false
    @State private var address = ""
    @State private var password = ""
    @State private var error: String?
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .choose:
                    VStack(spacing: 14) {
                        choice("扫一扫添加", "qrcode.viewfinder") {
                            showingScanner = true
                        }
                        choice("手动输入地址添加", "keyboard") {
                            address = ""
                            error = nil
                            step = .form
                        }
                        choice("局域网发现添加", "dot.radiowaves.left.and.right") {
                            error = nil
                            step = .discover
                            Task { await model.discover() }
                        }
                        Text("每台电脑的聊天、收藏和通知相互隔离；仅连接选中的电脑。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.top, 12)
                        Spacer()
                    }
                    .padding(20)
                case .form:
                    Form {
                        Section("电脑连接地址") {
                            TextField("例如 http://192.168.1.233:42819",
                                      text: $address)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("new-computer-address")
                        }
                        Section("连接验证") {
                            SecureField("访问密码（如已启用）", text: $password)
                            Text("使用当前设备名称：\(model.deviceName)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let error {
                            Text(error).foregroundStyle(.red).font(.footnote)
                        }
                        Button {
                            Task { await connectNewComputer() }
                        } label: {
                            HStack {
                                if connecting { ProgressView() }
                                Text("连接并保存电脑")
                            }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connecting || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                case .discover:
                    List {
                        if model.isDiscovering { ProgressView("正在搜索同一局域网中的电脑…") }
                        ForEach(model.discovered) { server in
                            Button {
                                address = server.origin
                                error = nil
                                step = .form
                            } label: {
                                Label(server.origin, systemImage: "desktopcomputer")
                            }
                        }
                        if let text = model.discoveryMessage {
                            Text(text).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("重新扫描") {
                            Task { await model.discover() }
                        }
                        .disabled(model.isDiscovering)
                    }
                }
            }
            .navigationTitle("添加电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .choose {
                        Button("返回") { step = .choose }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showingScanner) {
            QRScannerView(onScan: { scanned in
                showingScanner = false
                if let endpoint = try? ServerEndpoint(scanned.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    address = endpoint.origin
                    error = nil
                    step = .form
                } else {
                    error = "二维码不是有效的 Ferry 服务器地址。"
                    step = .form
                }
            }, onCancel: { showingScanner = false })
        }
    }

    private func choice(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.title3).frame(width: 30)
                Text(title).font(.body.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(17)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func connectNewComputer() async {
        guard !connecting else { return }
        guard let endpoint = try? ServerEndpoint(address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "请输入正确的 HTTP Ferry 电脑地址。"
            return
        }
        connecting = true
        error = nil
        // ServerEndpoint validation completes before changing the selected
        // origin. An unsuccessful join leaves the form open with its error.
        model.serverAddress = endpoint.origin
        model.accessPassword = password
        await model.connect()
        connecting = false
        if model.phase == .connected {
            onConnected()
        } else {
            error = model.statusMessage ?? "连接失败，请检查电脑地址和密码。"
        }
    }
}
