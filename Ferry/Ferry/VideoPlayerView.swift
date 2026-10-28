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
    /// When hosted by the mixed-media pager, close the whole viewer instead
    /// of dismissing a nonexistent nested presentation.
    var isActive: Bool = true
    var onClose: (() -> Void)? = nil
    var onVerticalDrag: ((CGFloat) -> Void)? = nil
    // Explicitly relay horizontal video swipes to the outer mixed-media pager.
    // AVPlayerLayer can consume a parent TabView page gesture on real devices.
    var onHorizontalSwipe: ((CGFloat) -> Void)? = nil

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
            Color.black
                .opacity(max(0, 1 - Double(abs(dragOffset) / 380)))
                .ignoresSafeArea()
            PlayerLayerView(player: player, onVerticalPan: { state, distance, velocity in
                switch state {
                case .changed:
                    dragOffset = distance
                    onVerticalDrag?(distance)
                case .ended:
                    if abs(distance) > 120 || abs(velocity) > 900 {
                        if let onClose { onClose() } else { dismiss() }
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            dragOffset = 0
                            onVerticalDrag?(0)
                        }
                    }
                case .cancelled, .failed:
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                        onVerticalDrag?(0)
                    }
                default:
                    break
                }
            }, onHorizontalSwipe: onHorizontalSwipe)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .scaleEffect(scale)
                .opacity(opacity)
                .offset(y: dragOffset)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
                // The UIKit vertical-only pan recognizer is installed on
                // PlayerContainerUIView. It rejects horizontal gestures
                // before recognition, leaving TabView paging uninterrupted.
        }
        .overlay(alignment: .topLeading) {
            Text(name).font(.headline).foregroundStyle(.white.opacity(0.92))
                .lineLimit(2).padding(20)
                .opacity(abs(dragOffset) > 0.5 ? 0 : 1)
                .allowsHitTesting(abs(dragOffset) <= 0.5)
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
                .opacity(abs(dragOffset) > 0.5 ? 0 : 1)
                .allowsHitTesting(abs(dragOffset) <= 0.5)
            }
        }
        .overlay { if showToast { toastView } }
        .statusBarHidden()
        .onAppear(perform: setup)
        .onChange(of: isActive) { _, active in
            if active {
                player.play()
                isPlaying = true
            } else {
                player.pause()
                isPlaying = false
            }
        }
        .onReceive(ticker) { _ in
            if isActive { updateTime() }
        }
        .onDisappear {
            player.pause()
            isPlaying = false
        }
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

    private func setup() {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if isActive {
            player.play()
            isPlaying = true
        }
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

/// The pan recognizer rejects horizontal movement in shouldBegin instead
/// of competing with the surrounding TabView's left/right swipe gesture.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let onVerticalPan: (UIGestureRecognizer.State, CGFloat, CGFloat) -> Void
    let onHorizontalSwipe: ((CGFloat) -> Void)?

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.player = player
        view.onVerticalPan = onVerticalPan
        view.onHorizontalSwipe = onHorizontalSwipe
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        uiView.player = player
        uiView.onVerticalPan = onVerticalPan
        uiView.onHorizontalSwipe = onHorizontalSwipe
    }
}

private final class PlayerContainerUIView: UIView, UIGestureRecognizerDelegate {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set { (layer as? AVPlayerLayer)?.player = newValue }
    }

    var onVerticalPan: ((UIGestureRecognizer.State, CGFloat, CGFloat) -> Void)?
    var onHorizontalSwipe: ((CGFloat) -> Void)?
    private var horizontalPan: UIPanGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleVerticalPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)
        let horizontal = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalPan(_:)))
        horizontal.delegate = self
        horizontal.cancelsTouchesInView = false
        horizontalPan = horizontal
        addGestureRecognizer(horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        if pan === horizontalPan {
            return onHorizontalSwipe != nil && abs(velocity.x) > abs(velocity.y) * 1.25
        }
        // Only a primarily vertical gesture closes the video player.
        return abs(velocity.y) > abs(velocity.x) * 1.25
    }

    @objc private func handleVerticalPan(_ pan: UIPanGestureRecognizer) {
        onVerticalPan?(pan.state, pan.translation(in: self).y, pan.velocity(in: self).y)
    }

    @objc private func handleHorizontalPan(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        let distance = pan.translation(in: self).x
        let velocity = pan.velocity(in: self).x
        if abs(distance) >= 65 || abs(velocity) >= 550 {
            onHorizontalSwipe?(distance != 0 ? distance : velocity)
        }
    }
}
