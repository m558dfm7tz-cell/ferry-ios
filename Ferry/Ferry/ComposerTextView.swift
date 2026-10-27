import SwiftUI
import UIKit

/// `UIViewRepresentable` replacement for the composer `TextField(axis: .vertical)`.
///
/// Root cause it fixes: with a standard SwiftUI TextField there is no hook into
/// the UIKit edit menu, and UIKit's default menu omits "全选" once a range is
/// already selected (e.g. after a double-tap selects a word). Wrapping a
/// `UITextView` lets us implement `textView(_:editMenuForTextIn:suggestedActions:)`
/// (iOS 16+) and re-add 全选 while keeping the system Cut/Copy/Paste actions.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var insertCommand: TextInsertion?
    let placeholder: String
    let isFocused: Binding<Bool>
    let maxLines: Int
    let textColor: UIColor
    let tintColor: UIColor
    let alwaysScrolls: Bool
    /// Minimum single-line height. The composer uses a taller value so the bar
    /// is easier to tap and read; the editor keeps the default (it scrolls).
    var minHeight: CGFloat = 20
    var onMentionChange: ((MentionContext?) -> Void)? = nil
    var accessibilityIdentifier: String? = nil
    /// Switch the real UITextView inputView from system keyboard to attachment
    /// controls; UIKit animates this in the keyboard's original safe area.
    var attachmentMode: Binding<Bool>? = nil
    var onAttachmentFile: (() -> Void)? = nil
    var onAttachmentCamera: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, isFocused: isFocused,
                    maxLines: maxLines, alwaysScrolls: alwaysScrolls,
                    minHeight: minHeight, onMentionChange: onMentionChange)
    }

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.backgroundColor = .clear
        // Center the placeholder on the *first* visible frame too; the old
        // zero inset relied on a later async measurement and jumped on resume.
        let oneLine = textView.font?.lineHeight ?? 20
        let centerInset = max(0, (minHeight - oneLine) / 2)
        textView.textContainerInset = UIEdgeInsets(top: centerInset, left: 0,
                                                   bottom: centerInset, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = alwaysScrolls
        textView.keyboardDismissMode = .interactive
        textView.contentInsetAdjustmentBehavior = .never
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.text = text
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.onTapWhileShowingAttachment = { [attachmentMode, isFocused] in
            guard attachmentMode?.wrappedValue == true else { return }
            attachmentMode?.wrappedValue = false
            isFocused.wrappedValue = true
        }

        textView.placeholderLabel.text = placeholder
        textView.placeholderLabel.font = textView.font
        textView.placeholderLabel.textColor = .placeholderText
        textView.placeholderLabel.isHidden = !text.isEmpty
        textView.placeholderLabel.isUserInteractionEnabled = false
        textView.addSubview(textView.placeholderLabel)
        textView.onWidthChanged = { [weak textView] in
            guard let textView else { return }
            // A reused UITextView can change width when the scene resumes.
            // Recompute text metrics once, avoiding per-frame relayout loops.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                context.coordinator.refreshLayout(textView)
            }
        }

        // Set the initial height once the view has a valid width.
        DispatchQueue.main.async {
            context.coordinator.refreshLayout(textView)
        }
        return textView
    }

    func updateUIView(_ textView: ComposerUITextView, context: Context) {
        if textView.text != text {
            textView.text = text
            // Defer the height recompute off this update pass so it never
            // mutates a binding synchronously (which would re-enter SwiftUI).
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                coordinator.refreshLayout(textView)
            }
        }
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.placeholderLabel.isHidden = !text.isEmpty

        if let command = insertCommand {
            // Apply on the next main-queue turn and clear the binding there
            // (never synchronously inside updateUIView, which would mutate
            // state during a view update and re-enter SwiftUI).
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                coordinator.applyInsertion(command, to: textView)
                insertCommand = nil
            }
        }

        let wantsAttachment = attachmentMode?.wrappedValue == true
        if wantsAttachment != textView.isShowingAttachmentInput {
            textView.isShowingAttachmentInput = wantsAttachment
            if wantsAttachment {
                let menu = context.coordinator.attachmentInputView()
                menu.onFile = onAttachmentFile
                menu.onCamera = onAttachmentCamera
                textView.inputView = menu
            } else {
                textView.inputView = nil
            }
            if textView.isFirstResponder { textView.reloadInputViews() }
        } else if wantsAttachment {
            let menu = context.coordinator.attachmentInputView()
            menu.onFile = onAttachmentFile
            menu.onCamera = onAttachmentCamera
        }
        context.coordinator.applyFocus(isFocused.wrappedValue, to: textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var height: Binding<CGFloat>
        private let isFocused: Binding<Bool>
        private let maxLines: Int
        private let alwaysScrolls: Bool
        private let minHeight: CGFloat
        private let onMentionChange: ((MentionContext?) -> Void)?
        /// The last focus state we acted on, so `updateUIView` only drives the
        /// first responder on an explicit transition (and never spuriously
        /// resigns a tap that just focused the text view).
        private var lastKnownFocus = false
        /// ID of the last insertion already applied, so a command that is
        /// dispatched more than once (before the parent clears the binding) is
        /// applied exactly once instead of growing the text each pass.
        private var lastAppliedInsertionID: UUID?
        private var attachmentMenu: FerryAttachmentInputView?

        fileprivate func attachmentInputView() -> FerryAttachmentInputView {
            if let attachmentMenu { return attachmentMenu }
            let menu = FerryAttachmentInputView()
            attachmentMenu = menu
            return menu
        }

        init(text: Binding<String>, height: Binding<CGFloat>, isFocused: Binding<Bool>,
             maxLines: Int, alwaysScrolls: Bool, minHeight: CGFloat,
             onMentionChange: ((MentionContext?) -> Void)?) {
            self.text = text
            self.height = height
            self.isFocused = isFocused
            self.maxLines = maxLines
            self.alwaysScrolls = alwaysScrolls
            self.minHeight = minHeight
            self.onMentionChange = onMentionChange
        }

        /// Keep the shared state in sync with UIKit's actual first responder.
        /// FocusState cannot represent the focus of a UIViewRepresentable unless
        /// a native SwiftUI focusable target participates in that FocusState.
        /// A plain Binding<Bool> avoids SwiftUI resetting focus behind UIKit.
        func textViewDidBeginEditing(_ textView: UITextView) {
            lastKnownFocus = true
            DispatchQueue.main.async { [weak textView] in
                guard textView?.isFirstResponder == true else { return }
                self.isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            lastKnownFocus = false
            DispatchQueue.main.async { [weak textView] in
                guard textView?.isFirstResponder != true else { return }
                self.isFocused.wrappedValue = false
            }
        }

        /// UIKit may also lose the responder during an input-view change.
        /// Reconcile a requested focus even if the binding itself did not
        /// change; never resign a user-initiated tap while FocusState is stale.
        func applyFocus(_ wantsFocus: Bool, to textView: UITextView) {
            if wantsFocus {
                lastKnownFocus = true
                if !textView.isFirstResponder {
                    if textView.window != nil {
                        textView.becomeFirstResponder()
                    } else {
                        DispatchQueue.main.async { [weak textView] in
                            guard self.isFocused.wrappedValue,
                                  let textView, textView.window != nil,
                                  !textView.isFirstResponder else { return }
                            textView.becomeFirstResponder()
                        }
                    }
                }
            } else if lastKnownFocus {
                lastKnownFocus = false
                if textView.isFirstResponder { textView.resignFirstResponder() }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            refreshLayout(textView)
            let context = MentionContext.detect(in: textView.text, cursor: textView.selectedRange.location)
            onMentionChange?(context)
        }

        /// Replace `command.range` with `command.text` and place the caret right
        /// after the inserted text. `textViewDidChange` is not called for this
        /// programmatic change, so the SwiftUI binding is synced manually.
        func applyInsertion(_ command: TextInsertion, to textView: UITextView) {
            guard command.id != lastAppliedInsertionID else { return }
            lastAppliedInsertionID = command.id
            let ns = (textView.text as NSString)
            let range = command.range
            guard range.location <= ns.length, range.length <= ns.length - range.location else { return }
            textView.text = ns.replacingCharacters(in: range, with: command.text)
            let caret = range.location + (command.text as NSString).length
            textView.selectedRange = NSRange(location: caret, length: 0)
            text.wrappedValue = textView.text
            refreshLayout(textView)
        }

        /// Recompute the auto-grow height (composer mode) or force scrolling
        /// (editor mode), and keep the placeholder in sync. Only toggles
        /// `isScrollEnabled` and the height binding when they actually change,
        /// so repeated layout passes never spin a SwiftUI update loop.
        func refreshLayout(_ textView: UITextView) {
            (textView as? ComposerUITextView)?.placeholderLabel.isHidden = !(textView.text.isEmpty)
            if alwaysScrolls {
                if !textView.isScrollEnabled { textView.isScrollEnabled = true }
                return
            }
            // Keep UITextView scrolling enabled continuously. Flipping this
            // flag during typing invalidated the text layout and sometimes
            // clipped everything after the first few characters.
            if !textView.isScrollEnabled { textView.isScrollEnabled = true }
            let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let lineHeight = font.lineHeight
            let width = max(48, textView.bounds.width - textView.textContainerInset.left
                                 - textView.textContainerInset.right
                                 - textView.textContainer.lineFragmentPadding * 2)
            let content = textView.text.isEmpty ? " " : textView.text!
            let textBounds = (content as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil)
            let neededHeight = max(lineHeight, ceil(textBounds.height) + 3)
            let minimum = max(lineHeight, minHeight)
            let maximum = max(minimum, lineHeight * CGFloat(max(1, maxLines)) + 5)
            let clamped = min(maximum, max(minimum, neededHeight))
            let insetTop = max(0, (clamped - neededHeight) / 2)
            let insets = UIEdgeInsets(top: insetTop, left: 0,
                                     bottom: insetTop, right: 0)
            if textView.textContainerInset != insets {
                textView.textContainerInset = insets
            }
            if abs(height.wrappedValue - clamped) > 1 {
                DispatchQueue.main.async { [weak textView] in
                    guard textView != nil else { return }
                    self.height.wrappedValue = clamped
                }
            }
            if textView.isFirstResponder {
                let selection = textView.selectedRange
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.isFirstResponder else { return }
                    let length = (textView.text as NSString).length
                    if selection.location <= length { textView.scrollRangeToVisible(selection) }
                }
            }
        }

        /// iOS 16+: put 全选 in the third slot of the edit menu (long-press and
        /// double-tap alike). The system omits it once a range is already
        /// selected (double-tap on a word), so we always supply our own and
        /// drop any duplicate the system happened to include. Cut/Copy/Paste
        /// and every other system action are kept as-is.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let length = (textView.text as NSString).length
            guard length > 0 else { return UIMenu(children: suggestedActions) }

            var actions = suggestedActions.filter { !Self.isSelectAll($0) }
            let selectAll = UIAction(title: "全选") { _ in
                textView.selectedRange = NSRange(location: 0, length: length)
            }
            actions.insert(selectAll, at: min(2, actions.count))
            return UIMenu(children: actions)
        }

        /// Titles the system uses for "select all" (the app ships zh-Hans, but
        /// the simulator/CI may run another language).
        private static let selectAllTitles: Set<String> = ["全选", "选择全部", "Select All"]

        private static func isSelectAll(_ element: UIMenuElement) -> Bool {
            if let action = element as? UIAction { return selectAllTitles.contains(action.title) }
            if let menu = element as? UIMenu { return selectAllTitles.contains(menu.title) }
            return false
        }
    }
}

/// `UITextView` subclass that hosts a placeholder label (shown when empty).
final class ComposerUITextView: UITextView {
    let placeholderLabel = UILabel()
    var isShowingAttachmentInput = false
    var onTapWhileShowingAttachment: (() -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleAttachmentTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func handleAttachmentTap() {
        if isShowingAttachmentInput {
            onTapWhileShowingAttachment?()
        }
        // Keep the native responder even when the scroll/keyboard gesture
        // recognizers compete for a tap on the empty composer.
        if !isFirstResponder { becomeFirstResponder() }
    }
    var onWidthChanged: (() -> Void)?
    private var lastLaidOutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 && abs(bounds.width - lastLaidOutWidth) > 1 {
            lastLaidOutWidth = bounds.width
            onWidthChanged?()
        }
        let origin = CGPoint(x: textContainerInset.left + textContainer.lineFragmentPadding,
                             y: max(0, (bounds.height - placeholderLabel.font.lineHeight) / 2))
        placeholderLabel.frame = CGRect(origin: origin,
                                        size: CGSize(width: bounds.width - origin.x * 2,
                                                     height: placeholderLabel.font.lineHeight))
        // Do not leave a single line scrolled upward after a UIKit
        // keyboard-to-attachment input-view replacement.
        if !text.contains("\n"), contentSize.height <= bounds.height + 2,
           abs(contentOffset.y) > 0.5 {
            contentOffset = .zero
        }
    }
}

/// UIKit attachment input view: replaces the software keyboard rather than
/// occupying a second SwiftUI sheet or resizing the transcript twice.
private final class FerryAttachmentInputView: UIInputView {
    var onFile: (() -> Void)?
    var onCamera: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 256),
                   inputViewStyle: .keyboard)
        backgroundColor = .secondarySystemBackground
        heightAnchor.constraint(equalToConstant: 256).isActive = true

        let file = makeButton("文件", symbol: "folder", action: #selector(openFile))
        let camera = makeButton("拍摄", symbol: "camera", action: #selector(openCamera))
        let row = UIStackView(arrangedSubviews: [file, camera])
        row.axis = .horizontal
        row.spacing = 16
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            row.heightAnchor.constraint(equalToConstant: 96)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePlacement = .top
        config.imagePadding = 10
        config.baseForegroundColor = .label
        config.background.backgroundColor = .tertiarySystemBackground
        config.cornerStyle = .large
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityIdentifier = title == "文件"
            ? "composer-attachment-file" : "composer-attachment-camera"
        return button
    }

    @objc private func openFile() { onFile?() }
    @objc private func openCamera() { onCamera?() }
}
