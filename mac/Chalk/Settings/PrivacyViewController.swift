import AppKit
import ChalkKit

/// What Chalk does with the user's data. Every claim is either checkable from
/// the Terminal or backed by evidence on screen; unsaved snapshots and
/// conflict copies are disclosed because they are the only user content kept
/// outside the user's own files.
final class PrivacyViewController: NSViewController {
    enum Section: Int, CaseIterable {
        case network, unsaved, conflicts, folder, logs, crash

        var title: String {
            switch self {
            case .network: return "What leaves this device"
            case .unsaved: return "Unsaved work"
            case .conflicts: return "Conflict copies"
            case .folder: return "Chalk\u{2019}s folder"
            case .logs: return "Logs"
            case .crash: return "After a crash"
            }
        }

        var footer: String {
            switch self {
            case .network:
                return "Chalk makes no network connections. There is no analytics, "
                     + "no telemetry, no crash reporter, no account, and no "
                     + "third-party code that phones home. A report leaves only "
                     + "when you file it yourself, as a GitHub issue, after "
                     + "reading it."
            case .unsaved:
                return "Chalk does not autosave. While a document has unsaved "
                     + "changes, its full text is written every 10 seconds, in "
                     + "plain text, to Chalk\u{2019}s own folder, so a crash does "
                     + "not cost you the work. Saving the document deletes its "
                     + "snapshot."
            case .conflicts:
                return "When a file changes outside Chalk and you save over it, "
                     + "the other version is kept as a complete copy named "
                     + "\u{201C}name.conflict.ext\u{201D}, next to your file where "
                     + "that is allowed and in Chalk\u{2019}s folder otherwise. "
                     + "Chalk never deletes these. It can only count the ones in "
                     + "its own folder, because it does not index your disk."
            case .folder:
                return "Everything above lives here. Nothing else in Chalk writes "
                     + "outside the files you open."
            case .logs:
                return "Chalk writes no log files. It logs to the system log like "
                     + "any app, and file names and paths are redacted there. The "
                     + "diagnostics a report can carry are counts and timings "
                     + "only: no file names, no paths, and none of your text."
            case .crash:
                return "A report contains no file names, paths or text. Turning "
                     + "this off is permanent: Chalk never switches it back on."
            }
        }
    }

    private let alpha: AlphaSession
    private let recovery = RecoveryStore(directory: RecoveryStore.appDirectory)
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private var stack: NSStackView?

    init(alpha: AlphaSession) {
        self.alpha = alpha
        super.init(nibName: nil, bundle: nil)
        title = "Privacy"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = ChromeToneView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        reloadRows()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The counts are live: reload so just-deleted snapshots disappear.
        reloadRows()
    }

    // MARK: - Rows

    /// Every row of a section, as (title, detail), so tests can read the screen without a snapshot.
    func rowsForTesting(_ section: Int) -> [(String, String?)] {
        rows(in: Section(rawValue: section)!).map { ($0.title, $0.detail) }
    }

    struct Row {
        let title: String
        var detail: String?
        var isDestructive = false
        var action: (() -> Void)?
        var toggle: Bool?
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .network:
            return [Row(title: "Network connections", detail: "None")]

        case .unsaved:
            let count = recovery.pendingCount()
            var rows = [
                Row(title: "Documents held", detail: "\(count)"),
                Row(title: "Space used", detail: Self.formatted(bytes: recovery.usage())),
            ]
            if let oldest = recovery.oldestPendingDate() {
                rows.append(Row(title: "Oldest", detail: Self.formatted(date: oldest)))
            }
            // clearPreviousLaunches, not clearAll: clearAll would delete the
            // live snapshot of a window being edited and disarm crash recovery
            // for the session. See RecoveryStore.
            rows.append(Row(title: "Delete Snapshots from Earlier Sessions",
                            isDestructive: true,
                            action: { [weak self] in self?.deleteEarlierSnapshots() }))
            return rows

        case .conflicts:
            return [Row(title: "Kept in Chalk\u{2019}s folder", detail: "\(conflictCopyCount())")]

        case .folder:
            return [Row(title: "Reveal in Finder", action: { [weak self] in self?.revealFolder() })]

        case .logs:
            return [Row(title: "Log files written", detail: "None")]

        case .crash:
            return [Row(title: "Ask me after a crash", toggle: alpha.isCrashPromptEnabled)]
        }
    }

    private func reloadRows() {
        stack?.removeFromSuperview()
        let cards = Section.allCases.map { section -> NSView in
            let rowViews = rows(in: section).map(makeRow)
            let card = SettingsCardView(title: section.title, rows: rowViews)
            let footer = NSTextField(wrappingLabelWithString: section.footer)
            footer.font = .systemFont(ofSize: 11)
            footer.textColor = .chalkTextMuted
            let group = NSStackView(views: [card, footer])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 8
            card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            footer.widthAnchor.constraint(equalTo: group.widthAnchor, constant: -SettingsRowView.inset * 2).isActive = true
            return group
        }
        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -margin),
        ])
        for card in cards { card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        self.stack = stack
    }

    private func makeRow(_ row: Row) -> SettingsRowView {
        var control: NSView?
        if let isOn = row.toggle {
            let toggle = NSSwitch()
            toggle.state = isOn ? .on : .off
            toggle.target = self
            toggle.action = #selector(crashPromptToggled)
            control = toggle
        }
        let view = SettingsRowView(title: row.title, detail: row.detail, control: control)
        if row.isDestructive { view.titleLabel.textColor = .systemRed }
        if let action = row.action { view.onClick = action }
        return view
    }

    // MARK: - Actions

    private func deleteEarlierSnapshots() {
        let removed = recovery.clearPreviousLaunches()
        Diagnostics.record(.recoveryPurged, a: removed)
        reloadRows()
    }

    private func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([RecoveryStore.chalkFolder])
    }

    @objc private func crashPromptToggled(_ sender: NSSwitch) {
        alpha.isCrashPromptEnabled = sender.state == .on
    }

    /// Only the copies in Chalk's own folder; the footer says so rather than indexing the disk.
    private func conflictCopyCount() -> Int {
        let files = try? FileManager.default.contentsOfDirectory(
            at: RecoveryStore.conflictCopiesDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        return files?.count ?? 0
    }

    private static func formatted(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func formatted(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
