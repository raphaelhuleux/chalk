import UIKit
import ChalkKit

/// Bug and feedback reporting, filed as a GitHub issue. The live preview shows the exact bytes that
/// will be filed; preview and payload both come from `BugReport.body`, so they cannot drift.
final class ReportProblemViewController: UIViewController {
    private let alpha: AlphaSession
    private let kindControl = UISegmentedControl(items: ["Bug", "Feedback"])
    private let notesView = UITextView()
    private let notesPlaceholder = UILabel()
    private let includeDiagnostics = UISwitch()
    private let previewView = UITextView()
    private let sendButton = UIButton(type: .system)

    /// Where reports go, also stated on screen.
    static let newIssuePage = "https://github.com/raphaelhuleux/chalk/issues/new"

    init(alpha: AlphaSession) {
        self.alpha = alpha
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Composition

    private var kind: BugReportKind { kindControl.selectedSegmentIndex == 0 ? .bug : .feedback }

    /// The single source for both the preview and what is sent.
    var composedBody: String {
        BugReport.body(
            kind: kind,
            notes: notesView.text ?? "",
            environment: alpha.build.reportEnvironment,
            diagnostics: includeDiagnostics.isOn ? Diagnostics.render() : nil)
    }

    var composedSubject: String {
        BugReport.subject(kind: kind, environment: alpha.build.reportEnvironment)
    }

    // MARK: - Test seams
    //
    // These drive the real controls and then call `refreshPreview`, the same refresh typing
    // triggers, so tests exercise the screen rather than a parallel model.

    var notesForTesting: String {
        get { notesView.text ?? "" }
        set { notesView.text = newValue; refreshPreview() }
    }

    var includeDiagnosticsForTesting: Bool {
        get { includeDiagnostics.isOn }
        set { includeDiagnostics.isOn = newValue; refreshPreview() }
    }

    var kindForTesting: BugReportKind {
        get { kind }
        set {
            kindControl.selectedSegmentIndex = newValue == .bug ? 0 : 1
            refreshPreview()
        }
    }

    var previewTextForTesting: String { previewView.text ?? "" }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Report a Problem"
        view.backgroundColor = .chalkChromeBackground

        kindControl.selectedSegmentIndex = 0
        kindControl.addTarget(self, action: #selector(refreshPreview), for: .valueChanged)

        notesView.font = .systemFont(ofSize: ChalkMetrics.s(13))
        notesView.backgroundColor = .chalkCardBackground
        notesView.textColor = .chalkTextBody
        notesView.layer.cornerRadius = ChalkMetrics.s(8)
        notesView.textContainerInset = UIEdgeInsets(
            top: ChalkMetrics.s(10), left: ChalkMetrics.s(8),
            bottom: ChalkMetrics.s(10), right: ChalkMetrics.s(8))
        notesView.delegate = self

        notesPlaceholder.text = "What happened? What did you expect instead?"
        notesPlaceholder.font = .systemFont(ofSize: ChalkMetrics.s(13))
        notesPlaceholder.textColor = .chalkTextMuted

        includeDiagnostics.isOn = true
        includeDiagnostics.onTintColor = .chalkAccent
        includeDiagnostics.addTarget(self, action: #selector(refreshPreview), for: .valueChanged)

        let diagnosticsLabel = UILabel()
        diagnosticsLabel.text = "Include diagnostics"
        diagnosticsLabel.font = .systemFont(ofSize: ChalkMetrics.s(13))
        diagnosticsLabel.textColor = .chalkTextBody

        let previewLabel = UILabel()
        previewLabel.text = "This is exactly what will be filed"
        previewLabel.font = .systemFont(ofSize: ChalkMetrics.s(11), weight: .semibold)
        previewLabel.textColor = .chalkTextMuted

        previewView.isEditable = false
        previewView.font = .monospacedSystemFont(ofSize: ChalkMetrics.s(10), weight: .regular)
        previewView.backgroundColor = .chalkCardBackground
        previewView.textColor = .chalkTextMuted
        previewView.layer.cornerRadius = ChalkMetrics.s(8)

        sendButton.setTitle("Open a GitHub Issue\u{2026}", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: ChalkMetrics.s(13), weight: .semibold)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)

        let footnote = UILabel()
        footnote.text = "Chalk does not send anything. This copies the report to the "
                      + "clipboard and opens a new issue on GitHub in your browser, with "
                      + "the report filled in; you press Submit. It needs a GitHub account.\n\n"
                      + "If Chalk crashed, macOS keeps its own crash report: "
                      + "Console \u{203A} Crash Reports. Attaching it helps a lot."
        footnote.numberOfLines = 0
        footnote.font = .systemFont(ofSize: ChalkMetrics.s(11))
        footnote.textColor = .chalkTextMuted

        let diagnosticsRow = UIStackView(arrangedSubviews: [diagnosticsLabel, includeDiagnostics])
        diagnosticsRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            kindControl, notesView, diagnosticsRow, previewLabel, previewView,
            sendButton, footnote,
        ])
        stack.axis = .vertical
        stack.spacing = ChalkMetrics.s(12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        notesPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        notesView.addSubview(notesPlaceholder)

        let margin = ChalkMetrics.s(16)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor,
                                          constant: -margin),
            notesView.heightAnchor.constraint(equalToConstant: ChalkMetrics.s(110)),
            previewView.heightAnchor.constraint(equalToConstant: ChalkMetrics.s(180)),
            notesPlaceholder.topAnchor.constraint(equalTo: notesView.topAnchor,
                                                  constant: ChalkMetrics.s(10)),
            notesPlaceholder.leadingAnchor.constraint(equalTo: notesView.leadingAnchor,
                                                      constant: ChalkMetrics.s(12)),
        ])
        refreshPreview()
    }

    @objc private func refreshPreview() {
        previewView.text = composedBody
        notesPlaceholder.isHidden = !(notesView.text ?? "").isEmpty
    }

    // MARK: - Sending

    /// Clipboard first, so a report the URL had to trim (or a browser that never opened) is still
    /// whole: the issue form is prefilled, and the full text is one paste away.
    @objc private func send() {
        let body = composedBody
        UIPasteboard.general.string = body
        let trimmed = BugReport.truncateForURL(body, limit: Self.urlBodyLimit)
        guard let url = BugReport.newIssueURL(
            base: Self.newIssuePage, title: composedSubject, body: trimmed) else {
            showCopiedNotice()
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened { self?.showCopiedNotice() }
        }
    }

    /// A guess: GitHub rejects very long prefill URLs, and percent-encoding grows the body. 4 000
    /// characters keeps the notes and build identity intact; `truncateForURL` trims only the
    /// diagnostics ring.
    private static let urlBodyLimit = 4_000

    private func showCopiedNotice() {
        presentChalkNotice(
            title: "Copied",
            message: "Your browser could not be opened, so the report is on the "
                   + "clipboard. File it at \(Self.newIssuePage).")
    }
}

extension ReportProblemViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) { refreshPreview() }
}
