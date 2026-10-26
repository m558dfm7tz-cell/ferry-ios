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
    var onMentionChange: ((MentionContext?) -> Void)? = nil
    var accessibilityIdentifier: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, isFocused: isFocused,
                    maxLines: maxLines, alwaysScrolls: alwaysScrolls,
                    onMentionChange: onMentionChange)
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
        textView.textContainerInset = .zero
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
            insertCommand = nil
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                coordinator.applyInsertion(command, to: textView)
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
        private let onMentionChange: ((MentionContext?) -> Void)?
        /// The last focus state we acted on, so `updateUIView` only drives the
        /// first responder on an explicit transition (and never spuriously
        /// resigns a tap that just focused the text view).
        private var lastKnownFocus = false

        init(text: Binding<String>, height: Binding<CGFloat>, isFocused: FocusState<Bool>.Binding,
             maxLines: Int, alwaysScrolls: Bool, onMentionChange: ((MentionContext?) -> Void)?) {
            self.text = text
            self.height = height
            self.isFocused = isFocused
            self.maxLines = maxLines
            self.alwaysScrolls = alwaysScrolls
            self.onMentionChange = onMentionChange
        }

        /// Drive the text view's first-responder state only on a transition of
        /// the focus binding. A tap on the text view focuses it and updates the
        /// binding via the delegate, so `updateUIView` must not then resign it.
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
            let ns = (textView.text as NSString)
            let range = command.range
            guard range.location <= ns.length, range.length <= ns.length - range.location else { return }
            textView.text = ns.replacingCharacters(in: range, with: command.text)
            let caret = range.location + (command.text as NSString).length
            textView.selectedRange = NSRange(location: caret, length: 0)
            text.wrappedValue = textView.text
            refreshLayout(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused.wrappedValue = true
            lastKnownFocus = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFocused.wrappedValue = false
            lastKnownFocus = false
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
            let wasScrolling = textView.isScrollEnabled
            textView.isScrollEnabled = false
            let width = textView.bounds.width > 0 ? textView.bounds.width : 200
            let fit = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let minHeight = textView.font?.lineHeight ?? 20
            let maxHeight = minHeight * CGFloat(max(maxLines, 1))
            let clamped = min(max(fit.height, minHeight), maxHeight)
            let shouldScroll = fit.height > maxHeight
            if wasScrolling != shouldScroll {
                textView.isScrollEnabled = shouldScroll
            }
            if abs(height.wrappedValue - clamped) > 0.5 {
                DispatchQueue.main.async { self.height.wrappedValue = clamped }
            }
        }

        /// iOS 16+: add 全选 when a partial range is selected (e.g. double-tap
        /// word), the exact case where the system menu omits it. Cut/Copy/Paste
        /// come from the system `suggestedActions` unchanged.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            var actions = suggestedActions
            let length = (textView.text as NSString).length
            let selection = textView.selectedRange
            if length > 0, selection.length > 0, selection.length < length {
                let selectAll = UIAction(title: "全选") { _ in
                    textView.selectedRange = NSRange(location: 0, length: length)
                }
                actions.append(selectAll)
            }
            return UIMenu(children: actions)
        }
    }
}

/// `UITextView` subclass that hosts a placeholder label (shown when empty).
final class ComposerUITextView: UITextView {
    let placeholderLabel = UILabel()

    override func layoutSubviews() {
        super.layoutSubviews()
        let origin = CGPoint(x: textContainerInset.left + textContainer.lineFragmentPadding,
                             y: textContainerInset.top)
        placeholderLabel.frame = CGRect(origin: origin,
                                        size: CGSize(width: bounds.width - origin.x * 2,
                                                     height: placeholderLabel.font.lineHeight))
    }
}
