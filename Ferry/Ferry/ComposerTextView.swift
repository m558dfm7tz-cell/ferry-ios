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
    let isFocused: FocusState<Bool>.Binding
    let maxLines: Int
    let textColor: UIColor
    let tintColor: UIColor
    let alwaysScrolls: Bool
    /// Minimum single-line height. The composer uses a taller value so the bar
    /// is easier to tap and read; the editor keeps the default (it scrolls).
    var minHeight: CGFloat = 20
    var onMentionChange: ((MentionContext?) -> Void)? = nil
    var accessibilityIdentifier: String? = nil

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
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.text = text
        textView.accessibilityIdentifier = accessibilityIdentifier

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

        context.coordinator.applyFocus(isFocused.wrappedValue, to: textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var height: Binding<CGFloat>
        private let isFocused: FocusState<Bool>.Binding
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

        init(text: Binding<String>, height: Binding<CGFloat>, isFocused: FocusState<Bool>.Binding,
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

        /// Drive the text view's first-responder state only on an explicit
        /// transition of the focus binding (e.g. the expand editor focusing on
        /// appear, or an explicit dismiss). The delegate deliberately does NOT
        /// write back to the focus binding, so a plain tap that focuses the
        /// text view can never be followed by SwiftUI writing `false` back and
        /// dismissing the keyboard right after it appears.
        func applyFocus(_ wantsFocus: Bool, to textView: UITextView) {
            guard wantsFocus != lastKnownFocus else { return }
            lastKnownFocus = wantsFocus
            if wantsFocus {
                if !textView.isFirstResponder { textView.becomeFirstResponder() }
            } else {
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
    var onWidthChanged: (() -> Void)?
    private var lastLaidOutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 && abs(bounds.width - lastLaidOutWidth) > 1 {
            lastLaidOutWidth = bounds.width
            onWidthChanged?()
        }
        let origin = CGPoint(x: textContainerInset.left + textContainer.lineFragmentPadding,
                             y: textContainerInset.top)
        placeholderLabel.frame = CGRect(origin: origin,
                                        size: CGSize(width: bounds.width - origin.x * 2,
                                                     height: placeholderLabel.font.lineHeight))
    }
}
