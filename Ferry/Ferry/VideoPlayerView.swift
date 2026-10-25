import SwiftUI
import AVFoundation
import Combine
import UIKit

/// Custom in-app video player (AVPlayer-based).
///
/// - Filename headline at the top.
/// - Play/pause + scrubbable progress slider at the bottom (single tap toggles
///   these playback controls).
/// - Save/share large round actions at the bottom-right (T3.1 style).
/// - Vertical drag-to-dismiss (WeChat-style); NO system QuickLook "Done" and
///   NO top-right X.
struct VideoPlayerView: View {
    let url: URL
    let name: String
    let mediaType: String

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var dragOffset: CGFloat = 0
    @State private var showToast = false
    @State private var toastText = ""

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .scaleEffect(scale)
                .opacity(opacity)
                .offset(y: dragOffset)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
                .gesture(dismissDrag)
        }
        .overlay(alignment: .topLeading) {
            Text(name).font(.headline).foregroundStyle(.white.opacity(0.92))
                .lineLimit(2).padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if showControls {
                VStack(spacing: 12) {
                    actionRow
                    playbackControls
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .overlay { if showToast { toastView } }
        .statusBarHidden()
        .onAppear(perform: setup)
        .onReceive(ticker) { _ in updateTime() }
        .onDisappear { player.pause() }
    }

    private var scale: CGFloat { 1 - min(1, abs(dragOffset) / 600) * 0.2 }
    private var opacity: Double { 1 - min(1, abs(dragOffset) / 400) * 0.6 }

    /// Save/share large round actions on their own row, above the playback
    /// controls, so they never cover the time labels or slider.
    private var actionRow: some View {
        HStack {
            Spacer()
            AttachmentActions(name: name, mediaType: mediaType,
                              load: { try? Data(contentsOf: url) }, tint: .white,
                              onToast: { text in flashToast(text) })
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 8) {
            Slider(value: $currentTime, in: 0...max(duration, 0.001)) { editing in
                isScrubbing = editing
                if !editing {
                    player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            .tint(.white)

            HStack(spacing: 10) {
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "暂停" : "播放")

                Text(TimeText.mmss(currentTime))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                Spacer()
                Text(TimeText.mmss(duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let velocityY = value.predictedEndTranslation.height
                if abs(dragOffset) > 120 || abs(velocityY) > 900 {
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
            }
    }

    private func setup() {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        isPlaying = true
    }

    private func togglePlay() {
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func updateTime() {
        guard !isScrubbing else { return }
        currentTime = player.currentTime().seconds
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
            duration = d
        }
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

/// Hosts an AVPlayerLayer as a UIView so SwiftUI can overlay controls on top.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        uiView.player = player
    }
}

private final class PlayerContainerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set { (layer as? AVPlayerLayer)?.player = newValue }
    }
}
