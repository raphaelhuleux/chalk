import AppKit
import PDFKit
import ChalkKit

/// PDFView that reports Cmd-clicks (reverse SyncTeX) instead of selecting.
final class SyncPDFView: PDFView {
    /// 1-based page and a point from the page's top-left corner, in PDF points.
    var onSyncClick: ((Int, CGPoint) -> Void)?

    /// The slot's resize handle overhangs this edge; PDFView's own cursor (an I-beam over text)
    /// would fight it there on every move.
    static let handleOverhang: CGFloat = 8

    private func isUnderHandle(_ event: NSEvent) -> Bool {
        convert(event.locationInWindow, from: nil).x < Self.handleOverhang
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isUnderHandle(event) else { return }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard !isUnderHandle(event) else { return }
        super.cursorUpdate(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let document else {
            super.mouseDown(with: event)
            return
        }
        let inView = convert(event.locationInWindow, from: nil)
        guard let page = page(for: inView, nearest: true) else { return }
        let inPage = convert(inView, to: page)
        let box = page.bounds(for: .mediaBox)
        onSyncClick?(document.index(for: page) + 1, CGPoint(x: inPage.x - box.minX, y: box.maxY - inPage.y))
    }
}

/// The compiled PDF in the editor column's trailing slot, sharing the outline
/// panel's frame (`EditorContainerViewController.trailingPanelContent`). A
/// header in the band like the outline's, the PDF, and a list of the last
/// compile's issues; the log replaces the PDF on demand.
final class PDFPanelViewController: NSViewController {
    var onCompile: (() -> Void)?
    /// Cmd-click in the PDF: 1-based page and a top-left point.
    var onSyncClick: ((Int, CGPoint) -> Void)?
    /// A click on an issue: its file (relative to the root's folder) and line.
    var onIssue: ((CompileIssue) -> Void)?

    private let edge = FlippedView()
    private let header = FlippedView()
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var compileButton: ChromeIconButton!
    private var logButton: ChromeIconButton!
    private let headerRule = FlippedView()
    private let pdfView = SyncPDFView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let logScroll = NSTextView.scrollableTextView()
    private let issuesRule = FlippedView()
    private let issuesStack = NSStackView()
    private let issuesScroll = NSScrollView()
    private var issuesHeight: NSLayoutConstraint?

    private(set) var shownPDF: URL?
    private var issues: [CompileIssue] = []
    private var showingLog = false
    /// Remove the flash a forward sync drew.
    private var highlightRemoval: DispatchWorkItem?

    private static let headerLeading: CGFloat = 22
    private static let headerTrailing: CGFloat = 10
    private static let issueRowHeight: CGFloat = 26
    private static let maxIssueRows = 5

    #if DEBUG
    var statusTextForTesting: String { statusLabel.stringValue }
    var issueCountForTesting: Int { issues.count }
    #endif

    override func loadView() {
        let root = ChromeToneView()
        root.onAppearanceChange = { [weak self] in self?.refreshColors() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        for hairline in [edge, headerRule, issuesRule] {
            hairline.wantsLayer = true
            hairline.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hairline)
        }

        eyebrowLabel.attributedStringValue = NSAttributedString(
            string: "PDF",
            attributes: [
                .font: NSFont.systemFont(ofSize: ChalkMetrics.sidebarCountFontSize, weight: .semibold),
                .kern: ChalkMetrics.sidebarCountFontSize * 0.08,
                .foregroundColor: NSColor.chalkTextFaint,
            ])
        nameLabel.font = .systemFont(ofSize: ChalkMetrics.sectionHeaderFontSize, weight: .semibold)
        nameLabel.textColor = .chalkChromeFg
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        statusLabel.font = .systemFont(ofSize: ChalkMetrics.outlineBadgeFontSize)
        statusLabel.textColor = .chalkChromeFgTertiary
        statusLabel.lineBreakMode = .byTruncatingTail
        compileButton = ChromeIconButton.make("play", label: "Compile") { [weak self] in self?.onCompile?() }
        logButton = ChromeIconButton.make("text.alignleft", label: "Show Log") { [weak self] in self?.toggleLog() }
        for v in [eyebrowLabel, nameLabel, statusLabel, compileButton!, logButton!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.onSyncClick = { [weak self] page, point in self?.onSyncClick?(page, point) }
        view.addSubview(pdfView)

        emptyLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
        emptyLabel.textColor = .chalkChromeFgTertiary
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.isHidden = true
        logScroll.drawsBackground = false
        if let text = logScroll.documentView as? NSTextView {
            text.isEditable = false
            text.drawsBackground = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .chalkChromeFgSecondary
            text.textContainerInset = NSSize(width: 12, height: 10)
        }
        view.addSubview(logScroll)

        issuesStack.orientation = .vertical
        issuesStack.alignment = .leading
        issuesStack.spacing = 0
        issuesStack.translatesAutoresizingMaskIntoConstraints = false
        let issuesDoc = FlippedView()
        issuesDoc.translatesAutoresizingMaskIntoConstraints = false
        issuesDoc.addSubview(issuesStack)
        issuesScroll.documentView = issuesDoc
        issuesScroll.drawsBackground = false
        issuesScroll.hasVerticalScroller = true
        issuesScroll.autohidesScrollers = true
        issuesScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(issuesScroll)

        let hair = 1 / max(1, view.window?.backingScaleFactor ?? 2)
        let issuesHeight = issuesScroll.heightAnchor.constraint(equalToConstant: 0)
        self.issuesHeight = issuesHeight
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edge.topAnchor.constraint(equalTo: view.topAnchor),
            edge.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: hair),

            header.topAnchor.constraint(equalTo: view.topAnchor, constant: OutlinePanelViewController.headerTop),
            header.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: Self.headerLeading),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.headerTrailing),
            eyebrowLabel.topAnchor.constraint(equalTo: header.topAnchor),
            eyebrowLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.firstBaselineAnchor.constraint(equalTo: eyebrowLabel.firstBaselineAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: compileButton.leadingAnchor, constant: -6),
            nameLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: compileButton.leadingAnchor, constant: -6),
            nameLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            logButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            logButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            compileButton.trailingAnchor.constraint(equalTo: logButton.leadingAnchor, constant: -2),
            compileButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            headerRule.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: hair),

            pdfView.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: issuesRule.topAnchor),
            logScroll.topAnchor.constraint(equalTo: pdfView.topAnchor),
            logScroll.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            logScroll.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            logScroll.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor, constant: -24),

            issuesRule.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            issuesRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            issuesRule.heightAnchor.constraint(equalToConstant: hair),
            issuesRule.bottomAnchor.constraint(equalTo: issuesScroll.topAnchor),
            issuesScroll.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            issuesScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            issuesScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            issuesHeight,
            issuesDoc.topAnchor.constraint(equalTo: issuesScroll.contentView.topAnchor),
            issuesDoc.leadingAnchor.constraint(equalTo: issuesScroll.contentView.leadingAnchor),
            issuesDoc.widthAnchor.constraint(equalTo: issuesScroll.contentView.widthAnchor),
            issuesStack.topAnchor.constraint(equalTo: issuesDoc.topAnchor, constant: 4),
            issuesStack.leadingAnchor.constraint(equalTo: issuesDoc.leadingAnchor, constant: 12),
            issuesStack.trailingAnchor.constraint(equalTo: issuesDoc.trailingAnchor, constant: -12),
            issuesStack.bottomAnchor.constraint(equalTo: issuesDoc.bottomAnchor, constant: -4),
        ])
        refreshColors()
        render(name: "", status: "", empty: "Nothing compiled yet.\nPress \u{2318}R to compile.")
    }

    private func refreshColors() {
        guard isViewLoaded else { return }
        for hairline in [edge, headerRule, issuesRule] {
            hairline.chalkSetLayerBackground(.chalkPaletteDivider, under: view.effectiveAppearance)
        }
        pdfView.backgroundColor = .chalkEditorBackground
    }

    private func render(name: String, status: String, empty: String?) {
        nameLabel.stringValue = name
        statusLabel.stringValue = status
        emptyLabel.stringValue = empty ?? ""
        emptyLabel.isHidden = empty == nil || showingLog
        pdfView.isHidden = showingLog || empty != nil
    }

    // MARK: State

    /// Show `state` for `root`, reloading the PDF when a run produced one.
    func show(root: URL?, state: CompileController.State?) {
        loadViewIfNeeded()
        guard let root else {
            setPDF(nil)
            setIssues([])
            render(name: "", status: "", empty: "Open a .tex, .md or .qmd file to compile it.")
            return
        }
        let pdf = CompileController.pdf(for: root)
        let status: String
        switch state?.phase ?? .idle {
        case .idle: status = ""
        case .running: status = "Compiling\u{2026}"
        case let .finished(ok):
            let errors = state?.issues.filter { $0.severity == .error }.count ?? 0
            status = ok ? (errors == 0 ? "Compiled" : "Compiled with errors") : "Failed"
        case .failed: status = "Failed"
        }
        if let text = logScroll.documentView as? NSTextView {
            text.string = state?.log ?? ""
            text.scrollToEndOfDocument(nil)
        }
        setIssues(state?.issues ?? [])
        if state?.phase != .running { setPDF(FileManager.default.fileExists(atPath: pdf.path) ? pdf : nil, reload: true) }
        var empty: String?
        if shownPDF == nil {
            if case let .failed(message) = state?.phase {
                empty = message
            } else if state?.phase == .running {
                empty = "Compiling\u{2026}"
            } else if case .finished = state?.phase {
                empty = "No PDF was produced. Show the log for details."
            } else {
                empty = "Not compiled yet.\nPress \u{2318}R to compile."
            }
        }
        render(name: pdf.lastPathComponent, status: status, empty: empty)
    }

    /// Load `pdf`, keeping the reader's page and scroll on a reload of the same file.
    private func setPDF(_ pdf: URL?, reload: Bool = false) {
        guard let pdf else {
            shownPDF = nil
            pdfView.document = nil
            return
        }
        if pdf == shownPDF, !reload { return }
        // Read the bytes first: PDFDocument(url:) maps the file lazily, and the
        // next compile rewrites it underneath.
        guard let data = try? Data(contentsOf: pdf), let document = PDFDocument(data: data) else { return }
        let keep = pdf == shownPDF ? pdfView.currentDestination : nil
        let keepIndex = keep?.page.flatMap { pdfView.document?.index(for: $0) }
        let scale = pdfView.scaleFactor
        let autoScales = pdfView.autoScales
        pdfView.document = document
        shownPDF = pdf
        if let keep, let keepIndex, let page = document.page(at: min(keepIndex, document.pageCount - 1)) {
            if !autoScales { pdfView.scaleFactor = scale }
            pdfView.go(to: PDFDestination(page: page, at: keep.point))
        }
    }

    private func setIssues(_ new: [CompileIssue]) {
        issues = new
        issuesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, issue) in new.enumerated() {
            let place = [issue.file, issue.line.map { "line \($0)" }].compactMap { $0 }.joined(separator: ":")
            let title = place.isEmpty ? issue.message : "\(place)  \(issue.message)"
            let button = NSButton(title: title, target: self, action: #selector(issueClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: ChalkMetrics.outlineBadgeFontSize),
                .foregroundColor: issue.severity == .error ? NSColor.systemRed : NSColor.chalkChromeFgTertiary,
            ])
            button.heightAnchor.constraint(equalToConstant: Self.issueRowHeight).isActive = true
            issuesStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: issuesStack.widthAnchor).isActive = true
        }
        issuesHeight?.constant = new.isEmpty ? 0 : CGFloat(min(new.count, Self.maxIssueRows)) * Self.issueRowHeight + 8
        issuesRule.isHidden = new.isEmpty
    }

    @objc private func issueClicked(_ sender: NSButton) {
        guard issues.indices.contains(sender.tag) else { return }
        onIssue?(issues[sender.tag])
    }

    private func toggleLog() {
        showingLog.toggle()
        logScroll.isHidden = !showingLog
        render(name: nameLabel.stringValue, status: statusLabel.stringValue,
               empty: shownPDF == nil ? emptyLabel.stringValue : nil)
    }

    // MARK: SyncTeX

    /// Scroll to a forward-sync hit and flash it.
    func reveal(_ hit: SyncTeX.PDFLocation) {
        guard let document = pdfView.document, let page = document.page(at: hit.page - 1) else { return }
        let box = page.bounds(for: .mediaBox)
        let height = max(hit.height, 10)
        let rect = CGRect(x: box.minX + hit.x - 2, y: box.maxY - hit.y - 3,
                          width: max(hit.width, 40) + 4, height: height + 6)
        pdfView.go(to: rect, on: page)
        highlightRemoval?.perform()
        let flash = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        flash.color = NSColor.systemYellow.withAlphaComponent(0.45)
        page.addAnnotation(flash)
        let removal = DispatchWorkItem { [weak page, weak flash] in
            if let page, let flash { page.removeAnnotation(flash) }
        }
        highlightRemoval = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: removal)
    }
}
