import SwiftUI
import AVFoundation
import Combine

/// In-app audio playback: play/pause, ±15s, and a progress slider, all with
/// Simplified-Chinese labels. Presented full-screen with its own 关闭 button.
struct AudioPlayerView: View {
    let url: URL
    let name: String
    let mediaType: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var errorMessage: String?
    @State private var showToast = false
    @State private var toastText = ""

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 72))
                    .foregroundStyle(.secondary)
                Text(name).font(.headline).lineLimit(2).multilineTextAlignment(.center)

                Slider(value: $currentTime, in: 0...max(duration, 0.001)) { editing in
                    if !editing { player?.currentTime = currentTime }
                }
                .tint(.cyan)

                HStack {
                    Text(TimeText.mmss(currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Text(TimeText.mmss(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                HStack(spacing: 44) {
                    Button { seek(-15) } label: { Image(systemName: "gobackward.15") }
                        .accessibilityLabel("后退 15 秒")
                    Button { togglePlay() } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 68))
                    }
                    .accessibilityLabel(isPlaying ? "暂停" : "播放")
                    Button { seek(15) } label: { Image(systemName: "goforward.15") }
                        .accessibilityLabel("前进 15 秒")
                }
                .font(.title)
                .foregroundStyle(.white)
                .buttonStyle(.plain)

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                Spacer()

                AttachmentActions(name: name, mediaType: mediaType,
                                  load: { try? Data(contentsOf: url) },
                                  onToast: { text in flashToast(text) })
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.chatBackground.ignoresSafeArea())
            .navigationTitle("音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.chatBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .onAppear(perform: setup)
            .onReceive(ticker) { _ in updateTime() }
            .onDisappear { player?.stop() }
            .overlay { if showToast { toastView } }
        }
    }

    private func setup() {
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.prepareToPlay()
            duration = audio.duration
            player = audio
            audio.play()
            isPlaying = true
        } catch {
            errorMessage = "无法播放音频。"
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func seek(_ delta: Double) {
        guard let player else { return }
        let target = max(0, min(player.duration, player.currentTime + delta))
        player.currentTime = target
        currentTime = target
    }

    private func updateTime() {
        guard let player else { return }
        currentTime = player.currentTime
        duration = player.duration
    }

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }

    private var toastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(toastText).foregroundStyle(.white).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.85), in: Capsule())
        .transition(.opacity)
    }
}
