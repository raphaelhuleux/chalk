import UIKit
import ChalkKit

/// WebKit's own text-selection highlight, switched off, since CodeMirror draws the selection.
/// CSS cannot hide it: WebKit paints it above the page in `caret-color` at alpha 0.2, which with
/// CodeMirror's transparent caret is a black film that dims text and misses CM's selection by up
/// to a row. The replaceable `highlightView` gets a view that draws nothing; the caret
/// and selection handles are untouched.
enum NativeSelectionHighlight {
    /// Replaces every selection highlight view in `root`'s subtree. Idempotent; returns the count.
    @discardableResult
    static func suppress(in root: UIView) -> Int {
        var replaced = 0
        var stack = [root]
        while let view = stack.popLast() {
            for case let display as UITextSelectionDisplayInteraction in view.interactions
            where !(display.highlightView is InertSelectionHighlightView) {
                display.highlightView = InertSelectionHighlightView()
                replaced += 1
            }
            stack.append(contentsOf: view.subviews)
        }
        return replaced
    }
}

/// A selection highlight that accepts its rects and paints nothing.
final class InertSelectionHighlightView: UIView, UITextSelectionHighlightView {
    var selectionRects: [UITextSelectionRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
    }
}
