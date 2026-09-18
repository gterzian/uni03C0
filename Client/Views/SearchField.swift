import AppKit
import SwiftUI

/// An AppKit `NSSearchField` used by the find bars (the session transcript's
/// and the code panes'). Chosen over the SwiftUI `TextField` because it takes
/// keyboard focus RELIABLY (`window.makeFirstResponder` — SwiftUI's
/// `@FocusState` is flaky inside a toolbar item, so typing right after Cmd+F
/// didn't land), it has no blue focus ring on activation
/// (`focusRingType = .none`), and the magnifier + clear button come built in.
/// Enter (its action) and Esc (`cancelOperation`) are intercepted via the field
/// editor's `doCommandBy`; arrow keys fall through untouched — cycling is
/// Enter's job, and only while the field is active.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onEnter: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEnter: onEnter, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchAction)
        field.stringValue = text
        // The field may be inserted asynchronously (a toolbar item animating
        // in) and so may not be in a window yet when this runs. Retry a few
        // times across the insertion; after that, never touch focus again (the
        // user can click elsewhere).
        for delay in [0.0, 0.08, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak field] in
                guard let field, field.window != nil else { return }
                if field.window?.firstResponder !== field {
                    field.window?.makeFirstResponder(field)
                }
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onEnter: () -> Void
        var onEscape: () -> Void

        init(text: Binding<String>, onEnter: @escaping () -> Void, onEscape: @escaping () -> Void) {
            self.text = text
            self.onEnter = onEnter
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField {
                text.wrappedValue = field.stringValue
            }
        }

        /// Esc (cancelOperation) closes the bar. Arrow keys are NOT
        /// intercepted here — Enter is the match cycler, and only while the
        /// search field is active.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            }
            return false
        }

        @objc func searchAction(_ sender: Any) {
            onEnter()
        }
    }
}
