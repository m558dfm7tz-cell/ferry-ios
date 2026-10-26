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
