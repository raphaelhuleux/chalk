import UIKit
import ChalkKit

/// What Chalk does with the user's data. Every claim is either checkable from the Terminal or backed
/// by evidence on screen; unsaved snapshots and conflict copies are disclosed because they are the
/// only user content kept outside the user's own files.
final class PrivacyViewController: UIViewController {
    private enum Section: Int, CaseIterable {
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
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(alpha: AlphaSession) {
        self.alpha = alpha
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Privacy"
        view.backgroundColor = .chalkChromeBackground
        tableView.backgroundColor = .chalkChromeBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The counts are live: reload so just-deleted snapshots disappear.
        reloadRows()
    }

    // MARK: - Rows

    /// Every row of a section, as (title, detail), so tests can read the screen without a snapshot.
    func rowsForTesting(_ section: Int) -> [(String, String?)] {
        rows(in: Section(rawValue: section)!).map { ($0.title, $0.detail) }
    }

    private struct Row {
        let title: String
        var detail: String?
        var isDestructive = false
        var action: (() -> Void)?
        var toggle: Bool?
    }

    /// What the table shows, by section. Built once per reload: the unsaved-work rows list the
    /// recovery folder several times, and the data source asks per row.
    private var sectionRows: [[Row]] = []

    private func reloadRows() {
        sectionRows = Section.allCases.map(rows(in:))
        tableView.reloadData()
    }

    private func row(at indexPath: IndexPath) -> Row? {
        guard sectionRows.indices.contains(indexPath.section),
              sectionRows[indexPath.section].indices.contains(indexPath.row) else { return nil }
        return sectionRows[indexPath.section][indexPath.row]
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
            // clearPreviousLaunches, not clearAll: clearAll would delete the live snapshot of a
            // window being edited and disarm crash recovery for the session. See RecoveryStore.
            rows.append(Row(title: "Delete Snapshots from Earlier Sessions",
                            isDestructive: true,
                            action: { [weak self] in self?.deleteEarlierSnapshots() }))
            return rows

        case .conflicts:
            return [Row(title: "Kept in Chalk\u{2019}s folder",
                        detail: "\(conflictCopyCount())")]

        case .folder:
            return [Row(title: "Reveal in Finder",
                        action: { [weak self] in self?.revealFolder() })]

        case .logs:
            return [Row(title: "Log files written", detail: "None")]

        case .crash:
            return [Row(title: "Ask me after a crash", toggle: alpha.isCrashPromptEnabled)]
        }
    }

    // MARK: - Actions

    private func deleteEarlierSnapshots() {
        let removed = recovery.clearPreviousLaunches()
        Diagnostics.record(.recoveryPurged, a: removed)
        reloadRows()
    }

    private func revealFolder() {
        // Unverified that a sandboxed Catalyst app can open its own container. If not, the fallback
        // is NSWorkspace.activateFileViewerSelecting via ChalkAppKitGlue.
        UIApplication.shared.open(RecoveryStore.chalkFolder)
    }

    @objc private func crashPromptToggled(_ sender: UISwitch) {
        alpha.isCrashPromptEnabled = sender.isOn
        // A cell rebuilt after scrolling reads the cache, which must not show the old state.
        sectionRows[Section.crash.rawValue] = rows(in: .crash)
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

extension PrivacyViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Section(rawValue: section)?.footer
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sectionRows.indices.contains(section) ? sectionRows[section].count : 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        guard let row = row(at: indexPath) else { return cell }
        cell.backgroundColor = .chalkCardBackground
        cell.textLabel?.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
        cell.textLabel?.text = row.title
        cell.textLabel?.textColor = row.isDestructive ? .systemRed : .chalkTextBody
        cell.detailTextLabel?.text = row.detail
        cell.detailTextLabel?.textColor = .chalkTextMuted
        cell.selectionStyle = row.action == nil ? .none : .default

        if let isOn = row.toggle {
            let toggle = UISwitch()
            toggle.isOn = isOn
            toggle.onTintColor = .chalkAccent
            toggle.addTarget(self, action: #selector(crashPromptToggled), for: .valueChanged)
            cell.accessoryView = toggle
        }
        return cell
    }
}

extension PrivacyViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.textColor = .chalkTextMuted
        header.textLabel?.font = .systemFont(ofSize: ChalkMetrics.s(11), weight: .semibold)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        row(at: indexPath)?.action?()
    }
}
