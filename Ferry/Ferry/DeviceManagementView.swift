import SwiftUI

/// 设备管理：列出已配对设备、标记当前设备、移除其他设备，并管理访问密码。
/// 服务器不提供“最后活跃时间”和“助手”设备类型，因此该页面只显示加入时间，
/// “助手”徽标完全基于名称的客户端启发式判断。
struct DeviceManagementView: View {
    let model: AppModel
    @State private var admin = DeviceAdminModel()

    @State private var activeAlert: ActiveAlert?
    @State private var passwordFlow: PasswordFlow?
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    private enum PasswordFlow: String, Identifiable {
        case enable, change
        var id: String { rawValue }
    }

    private enum ActiveAlert: Identifiable {
        case remove(Device)
        case disablePassword
        case setPassword

        var id: String {
            switch self {
            case .remove(let device): return "remove-\(device.id)"
            case .disablePassword: return "disable-password"
            case .setPassword: return "set-password"
            }
        }
    }

    private var activeAlertBinding: Binding<Bool> {
        Binding(get: { activeAlert != nil }, set: { if !$0 { activeAlert = nil } })
    }

    private var alertTitle: String {
        switch activeAlert {
        case .remove: return "移除设备"
        case .disablePassword: return "关闭访问密码"
        case .setPassword: return admin.passwordRequired ? "修改访问密码" : "启用访问密码"
        case .none: return ""
        }
    }

    var body: some View {
        List {
            devicesSection
            passwordSection
        }
        .navigationTitle("设备管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            admin.configure(endpoint: model.endpoint, token: model.token, currentDeviceID: model.currentDevice?.id)
            await admin.load()
        }
        .refreshable { await admin.load() }
        .sheet(item: $passwordFlow) { flow in
            AccessPasswordSheet(
                isChanging: flow == .change,
                newPassword: $newPassword,
                confirmPassword: $confirmPassword,
                onCancel: { passwordFlow = nil },
                onSubmit: {
                    passwordFlow = nil
                    activeAlert = .setPassword
                })
        }
        .alert(alertTitle, isPresented: activeAlertBinding, presenting: activeAlert) { alert in
            switch alert {
            case .remove(let device):
                Button("移除", role: .destructive) { Task { await admin.remove(device) } }
                Button("取消", role: .cancel) {}
            case .disablePassword:
                Button("关闭", role: .destructive) { Task { await admin.setPassword("") } }
                Button("取消", role: .cancel) {}
            case .setPassword:
                Button("确定", role: .destructive) { Task { await admin.setPassword(newPassword) } }
                Button("取消", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .remove(let device):
                Text("确定移除「\(device.name)」吗？该设备将无法再连接此 Ferry 服务器。")
            case .disablePassword:
                Text("关闭后，任何设备都可以加入此 Ferry 服务器。已连接的设备不受影响。")
            case .setPassword:
                Text("已连接的设备不会受到影响，密码仅用于新设备加入时验证。")
            }
        }
        .onChange(of: admin.shouldReturnToPairing) { _, revoked in
            if revoked {
                model.deviceWasRevoked()
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = admin.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
    }

    private var devicesSection: some View {
        Section {
            if admin.isLoading && admin.devices.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            ForEach(admin.sortedDevices) { device in
                deviceRow(device)
            }
        } header: {
            Text("已配对设备")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        var parts = ["服务器不记录设备的最后活跃时间，仅显示加入时间。"]
        if admin.devices.count <= 1 {
            parts.append("当前只有一台设备，无法移除。")
        } else {
            parts.append("当前设备无法移除（服务器会拒绝）。")
        }
        return parts.joined(separator: " ")
    }

    private func deviceRow(_ device: Device) -> some View {
        let isCurrent = device.id == admin.currentDeviceID
        let removable = !isCurrent && admin.devices.count > 1
        return HStack(spacing: 12) {
            Image(systemName: device.iconName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.body)
                    if device.isHelper {
                        Text("助手")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                    }
                }
                Text("加入于 \(device.joinedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Text("当前设备")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.green.opacity(0.2), in: Capsule())
                    .accessibilityIdentifier("current-device-badge")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if removable {
                Button("移除", role: .destructive) { activeAlert = .remove(device) }
                    .accessibilityIdentifier("remove-device-\(device.id)")
            }
        }
        .contextMenu {
            if removable {
                Button("移除", role: .destructive) { activeAlert = .remove(device) }
            }
        }
    }

    private var passwordSection: some View {
        Section {
            Toggle("访问密码", isOn: passwordToggle)
                .accessibilityIdentifier("access-password-toggle")
            if admin.passwordRequired {
                Button("修改密码") {
                    newPassword = ""
                    confirmPassword = ""
                    passwordFlow = .change
                }
                .accessibilityIdentifier("change-password")
            }
        } header: {
            Text("访问密码")
        } footer: {
            Text(admin.passwordRequired
                 ? "已启用。新设备加入时需要输入密码。修改密码不会影响已连接的设备。"
                 : "已关闭。启用后，新设备加入时需要输入密码。已连接的设备不受影响。")
        }
    }

    private var passwordToggle: Binding<Bool> {
        Binding(
            get: { admin.passwordRequired },
            set: { newValue in
                guard newValue != admin.passwordRequired else { return }
                if newValue {
                    newPassword = ""
                    confirmPassword = ""
                    passwordFlow = .enable
                } else {
                    activeAlert = .disablePassword
                }
            })
    }
}

/// 输入新访问密码的弹层（启用或修改共用）。
private struct AccessPasswordSheet: View {
    let isChanging: Bool
    @Binding var newPassword: String
    @Binding var confirmPassword: String
    let onCancel: () -> Void
    let onSubmit: () -> Void

    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("新密码", text: $newPassword)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("new-password")
                    SecureField("确认新密码", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("confirm-password")
                } footer: {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    } else {
                        Text("密码用于新设备加入时验证。已连接的设备不受影响。")
                    }
                }
            }
            .navigationTitle(isChanging ? "修改访问密码" : "启用访问密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) { Button("继续") { submit() } }
            }
        }
        .onAppear { errorText = nil }
    }

    private func submit() {
        if let error = AccessPasswordValidator.validate(newPassword, confirm: confirmPassword) {
            errorText = error
        } else {
            onSubmit()
        }
    }
}
