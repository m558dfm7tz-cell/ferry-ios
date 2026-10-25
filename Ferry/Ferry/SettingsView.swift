import SwiftUI

/// App settings. Currently only the video-send behavior toggle: by default
/// videos are transcoded to MP4 before upload; enable "发送原始视频" to send
/// the original container unchanged.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ferry.sendOriginalVideo") private var sendOriginalVideo = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("发送视频时不转换格式", isOn: $sendOriginalVideo)
                    Text("关闭时，从相册或相机发送的视频会默认转码为 MP4（H.264/AAC），兼容性更好。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("视频发送")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
    }
}
