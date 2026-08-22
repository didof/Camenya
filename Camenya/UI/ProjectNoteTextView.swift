import SwiftUI
import UIKit

struct ProjectNoteTextView: UIViewRepresentable {
    @Binding var text: String
    let navigationState: ProjectNoteNavigationState
    let onNavigationChanged: (ProjectNoteNavigationState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .preferredFont(forTextStyle: .title3)
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 16, bottom: 24, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.accessibilityLabel = "Project Note"
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if textView.text != text {
            context.coordinator.isUpdatingProgrammatically = true
            textView.text = text
            context.coordinator.isUpdatingProgrammatically = false
        }

        context.coordinator.restoreNavigationIfNeeded(in: textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ProjectNoteTextView
        var isUpdatingProgrammatically = false
        private var restoredNavigation = false

        init(parent: ProjectNoteTextView) {
            self.parent = parent
        }

        func restoreNavigationIfNeeded(in textView: UITextView) {
            guard !restoredNavigation else { return }
            restoredNavigation = true
            let state = parent.navigationState.normalized(for: textView.text)

            isUpdatingProgrammatically = true
            textView.selectedRange = NSRange(location: state.cursorUTF16Offset, length: 0)
            textView.layoutIfNeeded()
            textView.setContentOffset(
                CGPoint(x: 0, y: CGFloat(state.verticalScrollOffset)),
                animated: false
            )
            isUpdatingProgrammatically = false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingProgrammatically else { return }
            parent.text = textView.text
            publishNavigation(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            publishNavigation(from: textView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            publishNavigation(from: textView)
        }

        private func publishNavigation(from textView: UITextView) {
            guard !isUpdatingProgrammatically else { return }
            parent.onNavigationChanged(
                ProjectNoteNavigationState(
                    cursorUTF16Offset: textView.selectedRange.location,
                    verticalScrollOffset: max(Double(textView.contentOffset.y), 0)
                )
            )
        }
    }
}
