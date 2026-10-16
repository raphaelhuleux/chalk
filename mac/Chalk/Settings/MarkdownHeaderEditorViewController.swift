import AppKit
import ChalkKit

/// Settings > Compile > Default YAML Header > Edit: the header a .md/.qmd file without one
/// compiles with. A sheet with a monospaced editor; Save writes `Preferences.markdownDefaultHeader`.
final class MarkdownHeaderEditorViewController: NSViewController {
    var onSave: (() -> Void)?
    private let textView = NSTextView()

    #if DEBUG
    var textForTesting: String {
        get { textView.string }
        set { textView.string = newValue }
    }
    func saveForTesting() { save() }
    #endif

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        view = root

        let title = NSTextField(labelWithString: "Default YAML Header")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString:
            "Used when a .md or .qmd file has no YAML header of its own. Chalk compiles a copy with this header on top; your file is not changed.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.string = Preferences.markdownDefaultHeader
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let reset = NSButton(title: "Use Suggested", target: self, action: #selector(useSuggested))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [reset, spacer, cancel, save])
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for v in [title, hint, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    @objc private func useSuggested() {
        textView.string = Preferences.suggestedMarkdownHeader
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func save() {
        Preferences.markdownDefaultHeader = textView.string
        onSave?()
        if presentingViewController != nil { dismiss(nil) }
    }
}
