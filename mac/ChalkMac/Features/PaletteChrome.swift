import AppKit
import ChalkKit

/// The palette card's content view. ⌘↩ is a key equivalent, which AppKit
/// offers to the view tree before the menu and never to the field editor's
/// command path, so it is caught here.
final class PaletteContentView: FlippedView {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers == "\r", let onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A key badge ("esc", "return"): small text in a hairline ring.
final class KeyBadgeView: FlippedView {
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    init(text: String, color: NSColor, width: CGFloat? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.cornerRadius = ChalkMetrics.s(5)
        label.stringValue = text
        label.font = .systemFont(ofSize: ChalkMetrics.s(10.5))
        label.textColor = color
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var constraints = [
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: ChalkMetrics.s(20)),
        ]
        if let width {
            constraints.append(widthAnchor.constraint(equalToConstant: width))
        } else {
            constraints.append(widthAnchor.constraint(equalTo: label.widthAnchor, constant: 12))
        }
        NSLayoutConstraint.activate(constraints)
        refreshEdge()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: ChalkAppearance.themeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func themeDidChange() { refreshEdge() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshEdge()
    }

    /// A layer colour does not follow a dynamic colour: re-resolve on appearance and theme flips.
    private func refreshEdge() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.chalkKeyBadgeEdge.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { super.mouseDown(with: event); return }
        onClick()
    }
}

/// A palette row's content knows whether its row is the keyboard's.
protocol PaletteRowContent: AnyObject {
    func setHighlighted(_ highlighted: Bool)
}

/// A palette result row: the accent wash pill while selected, nothing otherwise.
final class PaletteRowView: NSTableRowView {
    override var isFlipped: Bool { true }

    override var isSelected: Bool {
        didSet { (subviews.first as? PaletteRowContent)?.setHighlighted(isSelected) }
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // The table is already inset from the card, so the pill spans the row minus a hair.
        let rect = bounds.insetBy(dx: 0, dy: 1)
        NSColor.chalkAccentSelection.setFill()
        NSBezierPath(roundedRect: rect, xRadius: ChalkMetrics.paletteRowRadius,
                     yRadius: ChalkMetrics.paletteRowRadius).fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {}
}

/// The shared frame of both palettes: an input row (glyph, field, esc badge),
/// a hairline, the results table, and a footer with the key hints and a
/// count. The owner wires the field's and table's delegates to itself.
final class PaletteFrame {
    static let inputRowHeight: CGFloat = ChalkMetrics.s(48)
    static let footerHeight: CGFloat = ChalkMetrics.s(33)
    static let resultsPadding: CGFloat = ChalkMetrics.s(8)

    let searchField = NSTextField()
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let countLabel = NSTextField(labelWithString: "")
    /// Centered over the results, for a palette with nothing to list.
    let emptyLabel = NSTextField(labelWithString: "")
    private let escBadge: KeyBadgeView
    private let glyphName: String
    private let placeholder: String
    private let hints: String
    private let rowHeight: CGFloat

    init(glyph: String, placeholder: String, hints: String, rowHeight: CGFloat) {
        glyphName = glyph
        self.placeholder = placeholder
        self.hints = hints
        self.rowHeight = rowHeight
        escBadge = KeyBadgeView(text: "esc", color: .chalkChromeFgQuaternary)
    }

    /// Build the frame into `view`. `onEscape` is the badge's click.
    func install(in view: NSView, onEscape: @escaping () -> Void) {
        let inputRow = FlippedView()
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChalkMetrics.s(14), weight: .regular))
        glyph.contentTintColor = .chalkChromeFgTertiary
        glyph.imageScaling = .scaleNone
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        searchField.font = .systemFont(ofSize: ChalkMetrics.paletteSearchFontSize)
        searchField.textColor = .chalkChromeFg
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none // the accent caret is the only focus cue
        searchField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.chalkChromeFgQuaternary,
                         .font: NSFont.systemFont(ofSize: ChalkMetrics.paletteSearchFontSize)])
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        escBadge.onClick = onEscape
        escBadge.setAccessibilityLabel("Close")
        escBadge.translatesAutoresizingMaskIntoConstraints = false

        inputRow.addSubview(glyph)
        inputRow.addSubview(searchField)
        inputRow.addSubview(escBadge)

        let divider = Self.hairline()

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        // The field keeps the keyboard; a click on a row must not take it.
        tableView.refusesFirstResponder = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Self.resultsPadding, left: 0, bottom: Self.resultsPadding, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
        emptyLabel.textColor = .chalkChromeFgQuaternary
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = FlippedView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerHairline = Self.hairline()
        footer.addSubview(footerHairline)

        let hintsLabel = NSTextField(labelWithString: hints)
        hintsLabel.font = .systemFont(ofSize: ChalkMetrics.paletteHintFontSize)
        hintsLabel.textColor = .chalkChromeFgQuaternary
        hintsLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(hintsLabel)

        countLabel.font = .systemFont(ofSize: ChalkMetrics.paletteHintFontSize)
        countLabel.textColor = .chalkChromeFgQuaternary
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(countLabel)

        view.addSubview(inputRow)
        view.addSubview(divider)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            inputRow.topAnchor.constraint(equalTo: view.topAnchor),
            inputRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputRow.heightAnchor.constraint(equalToConstant: Self.inputRowHeight),

            glyph.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor, constant: ChalkMetrics.s(16)),
            glyph.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: ChalkMetrics.s(10)),
            searchField.trailingAnchor.constraint(equalTo: escBadge.leadingAnchor, constant: -ChalkMetrics.s(10)),
            searchField.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            escBadge.trailingAnchor.constraint(equalTo: inputRow.trailingAnchor, constant: -ChalkMetrics.s(16)),
            escBadge.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),

            divider.topAnchor.constraint(equalTo: inputRow.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChalkMetrics.s(12)),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChalkMetrics.s(12)),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChalkMetrics.s(8)),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChalkMetrics.s(8)),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footerHairline.topAnchor.constraint(equalTo: footer.topAnchor),
            footerHairline.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerHairline.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerHairline.heightAnchor.constraint(equalToConstant: 0.5),
            hintsLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: ChalkMetrics.s(16)),
            hintsLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            countLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: hintsLabel.trailingAnchor, constant: ChalkMetrics.s(14)),
            countLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -ChalkMetrics.s(16)),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    private static func hairline() -> NSView {
        let line = FlippedView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.layer?.backgroundColor = NSColor.chalkPaletteDivider.cgColor
        return line
    }

    /// The field editor for the search field, dressed: no smart substitutions
    /// in a filename or heading query, and the accent caret.
    static func dress(fieldEditor: NSTextView) {
        fieldEditor.isAutomaticQuoteSubstitutionEnabled = false
        fieldEditor.isAutomaticDashSubstitutionEnabled = false
        fieldEditor.isAutomaticTextReplacementEnabled = false
        fieldEditor.isAutomaticSpellingCorrectionEnabled = false
        fieldEditor.isContinuousSpellCheckingEnabled = false
        fieldEditor.insertionPointColor = .chalkAccent
    }

    /// The palettes' shared command set in the field: Up/Down move the row,
    /// Escape cancels, Return confirms. nil for anything else.
    enum FieldCommand { case up, down, cancel, confirm }

    static func command(for selector: Selector) -> FieldCommand? {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): return .up
        case #selector(NSResponder.moveDown(_:)): return .down
        case #selector(NSResponder.cancelOperation(_:)): return .cancel
        case #selector(NSResponder.insertNewline(_:)): return .confirm
        default: return nil
        }
    }
}

/// Accent highlight on a prefix match: the matched run in the accent, semibold.
func paletteHighlightedTitle(_ text: String, query: String, baseWeight: NSFont.Weight,
                             size: CGFloat) -> NSAttributedString {
    let attributed = NSMutableAttributedString(
        string: text,
        attributes: [.foregroundColor: NSColor.chalkChromeFg,
                     .font: NSFont.systemFont(ofSize: size, weight: baseWeight)])
    if !query.isEmpty, text.lowercased().hasPrefix(query.lowercased()),
       let range = text.range(of: text.prefix(query.count)) {
        attributed.addAttributes([
            .foregroundColor: NSColor.chalkAccent,
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        ], range: NSRange(range, in: text))
    }
    return attributed
}
