import AppKit
import ChalkKit

/// Bug and feedback reporting, filed as a GitHub issue. The live preview
/// shows the exact bytes that will be filed; preview and payload both come
/// from `BugReport.body`, so they cannot drift.
final class ReportProblemViewController: NSViewController, NSTextViewDelegate {
    private let alpha: AlphaSession
    private let kindControl = NSSegmentedControl(labels: ["Bug", "Feedback"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let notesView = NSTextView()
    private let notesPlaceholder = NSTextField(labelWithString: "What happened? What did you expect instead?")
    private let includeDiagnostics = NSSwitch()
    private let previewView = NSTextView()
    private let sendButton = NSButton(title: "Open a GitHub Issue\u{2026}", target: nil, action: nil)

    /// Where reports go, also stated on screen.
    static let newIssuePage = "https://github.com/raphaelhuleux/chalk/issues/new"

    init(alpha: AlphaSession) {
        self.alpha = alpha
        super.init(nibName: nil, bundle: nil)
        title = "Report a Problem"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Composition

    private var kind: BugReportKind { kindControl.selectedSegment == 0 ? .bug : .feedback }

    /// The single source for both the preview and what is sent.
    var composedBody: String {
        BugReport.body(
            kind: kind,
            notes: notesView.string,
            environment: alpha.build.reportEnvironment,
            diagnostics: includeDiagnostics.state == .on ? Diagnostics.render() : nil)
    }

    var composedSubject: String {
        BugReport.subject(kind: kind, environment: alpha.build.reportEnvironment)
    }

    // MARK: - Test seams
    //
    // These drive the real controls and then call `refreshPreview`, the same
    // refresh typing triggers, so tests exercise the screen rather than a
    // parallel model.

    var notesForTesting: String {
        get { notesView.string }
        set { notesView.string = newValue; refreshPreview() }
    }

    var includeDiagnosticsForTesting: Bool {
        get { includeDiagnostics.state == .on }
        set { includeDiagnostics.state = newValue ? .on : .off; refreshPreview() }
    }

    var kindForTesting: BugReportKind {
        get { kind }
        set {
            kindControl.selectedSegment = newValue == .bug ? 0 : 1
            refreshPreview()
        }
    }

    var previewTextForTesting: String { previewView.string }

    // MARK: - View

    override func loadView() {
        view = ChromeToneView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        kindControl.selectedSegment = 0
        kindControl.selectedSegmentBezelColor = .chalkAccent
        kindControl.target = self
        kindControl.action = #selector(refreshPreview)

        let notesScroll = Self.makeTextScroll(notesView, editable: true,
                                              font: .systemFont(ofSize: ChalkMetrics.s(13)),
                                              color: .chalkTextBody)
        notesView.delegate = self
        notesView.isAutomaticQuoteSubstitutionEnabled = false
        notesView.isAutomaticDashSubstitutionEnabled = false
        notesPlaceholder.font = .systemFont(ofSize: ChalkMetrics.s(13))
        notesPlaceholder.textColor = .chalkTextMuted
        notesPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        notesScroll.addSubview(notesPlaceholder)

        includeDiagnostics.state = .on
        includeDiagnostics.target = self
        includeDiagnostics.action = #selector(refreshPreview)

        let diagnosticsLabel = NSTextField(labelWithString: "Include diagnostics")
        diagnosticsLabel.font = .systemFont(ofSize: ChalkMetrics.s(13))
        diagnosticsLabel.textColor = .chalkTextBody

        let previewLabel = NSTextField(labelWithString: "This is exactly what will be filed")
        previewLabel.font = .systemFont(ofSize: ChalkMetrics.s(11), weight: .semibold)
        previewLabel.textColor = .chalkTextMuted

        let previewScroll = Self.makeTextScroll(previewView, editable: false,
                                                font: .monospacedSystemFont(ofSize: ChalkMetrics.s(10), weight: .regular),
                                                color: .chalkTextMuted)

        sendButton.bezelStyle = .rounded
        sendButton.font = .systemFont(ofSize: ChalkMetrics.s(13), weight: .semibold)
        sendButton.target = self
        sendButton.action = #selector(send)

        let footnote = NSTextField(wrappingLabelWithString:
            "Chalk does not send anything. This copies the report to the "
            + "clipboard and opens a new issue on GitHub in your browser, with "
            + "the report filled in; you press Submit. It needs a GitHub account.\n\n"
            + "If Chalk crashed, macOS keeps its own crash report: "
            + "Console \u{203A} Crash Reports. Attaching it helps a lot.")
        footnote.font = .systemFont(ofSize: ChalkMetrics.s(11))
        footnote.textColor = .chalkTextMuted

        let diagnosticsRow = NSStackView(views: [diagnosticsLabel, includeDiagnostics])
        diagnosticsRow.orientation = .horizontal
        diagnosticsRow.alignment = .centerY

        let stack = NSStackView(views: [
            kindControl, notesScroll, diagnosticsRow, previewLabel, previewScroll, sendButton, footnote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ChalkMetrics.s(12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let margin = ChalkMetrics.s(16)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -margin),
            notesScroll.heightAnchor.constraint(equalToConstant: ChalkMetrics.s(110)),
            notesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewScroll.heightAnchor.constraint(equalToConstant: ChalkMetrics.s(180)),
            previewScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footnote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notesPlaceholder.topAnchor.constraint(equalTo: notesScroll.topAnchor, constant: ChalkMetrics.s(10)),
            notesPlaceholder.leadingAnchor.constraint(equalTo: notesScroll.leadingAnchor, constant: ChalkMetrics.s(12)),
        ])
        refreshPreview()
    }

    /// A rounded card holding a text view.
    private static func makeTextScroll(_ textView: NSTextView, editable: Bool, font: NSFont, color: NSColor) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = ChalkMetrics.s(8)
        scroll.layer?.cornerCurve = .continuous
        scroll.drawsBackground = true
        scroll.backgroundColor = .chalkCardBackground
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = editable
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = .chalkAccent
        textView.textContainerInset = NSSize(width: ChalkMetrics.s(8), height: ChalkMetrics.s(10))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    @objc private func refreshPreview() {
        previewView.string = composedBody
        notesPlaceholder.isHidden = !notesView.string.isEmpty
    }

    func textDidChange(_ notification: Notification) { refreshPreview() }

    // MARK: - Sending

    /// Clipboard first, so a report the URL had to trim (or a browser that
    /// never opened) is still whole: the issue form is prefilled, and the
    /// full text is one paste away.
    @objc private func send() {
        let body = composedBody
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        let trimmed = BugReport.truncateForURL(body, limit: Self.urlBodyLimit)
        guard let url = BugReport.newIssueURL(base: Self.newIssuePage, title: composedSubject, body: trimmed),
              NSWorkspace.shared.open(url) else {
            showCopiedNotice()
            return
        }
    }

    /// A guess: GitHub rejects very long prefill URLs, and percent-encoding
    /// grows the body. 4 000 characters keeps the notes and build identity
    /// intact; `truncateForURL` trims only the diagnostics ring.
    private static let urlBodyLimit = 4_000

    private func showCopiedNotice() {
        presentChalkNotice(
            title: "Copied",
            message: "Your browser could not be opened, so the report is on the "
                   + "clipboard. File it at \(Self.newIssuePage).")
    }
}
