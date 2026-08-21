import SwiftUI
import UIKit

struct CursorAwareCaptionTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var cursorOffset: Int
    let isFirstResponder: Bool
    let onSplit: () -> Void
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        view.accessibilityLabel = "Caption text"

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(
                title: "Split at Cursor",
                style: .plain,
                target: context.coordinator,
                action: #selector(Coordinator.split)
            ),
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(
                title: "Done",
                style: .done,
                target: context.coordinator,
                action: #selector(Coordinator.done)
            )
        ]
        view.inputAccessoryView = toolbar
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if isFirstResponder, !view.isFirstResponder {
            view.becomeFirstResponder()
            let offset = min(max(0, cursorOffset), view.text.utf16.count)
            view.selectedRange = NSRange(location: offset, length: 0)
        } else if !isFirstResponder, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CursorAwareCaptionTextView

        init(parent: CursorAwareCaptionTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.cursorOffset = textView.selectedRange.location
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.cursorOffset = textView.selectedRange.location
        }

        @objc func split() { parent.onSplit() }

        @objc func done() {
            parent.onDone()
        }
    }
}
