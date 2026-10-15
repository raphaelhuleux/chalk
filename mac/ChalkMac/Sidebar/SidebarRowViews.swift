import AppKit
import ChalkKit

/// The Library's outline view. The key claims and the row context menu live on
/// the view because AppKit routes both to the view that is first responder or
/// under the pointer, never to the controller.
final class LibraryOutlineView: NSOutlineView {
    /// The keys the tree claims beyond the table's own (Up/Down, type-select).
    /// Return and keypad Enter are deliberately absent (decision 2026-08-15):
    /// activation is Space, so the sidebar never eats the editor's Return.
    enum KeyClaim: CaseIterable {
        case rename, activate, fold, unfold

        var input: String {
            switch self {
            case .rename: return String(UnicodeScalar(NSF2FunctionKey)!)
            case .activate: return " "
            case .fold: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .unfold: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
            }
        }
    }

    /// Handle a claimed key; false lets the table's own handling run.
    var onKeyClaim: ((KeyClaim) -> Bool)?
    /// The context menu for the row under the pointer (-1 for blank space).
    var onMenuForRow: ((Int) -> NSMenu?)?
    var onDraggingExited: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// The disclosure triangle is the cell's own chevron, so the table's is
    /// given no frame. Not `shouldShowOutlineCell`: an item whose outline cell
    /// is hidden that way is one AppKit refuses to collapse (`collapseItem`
    /// returns before asking the delegate).
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    /// The cell spans the row from its leading edge; the cell indents itself
    /// (`LibraryCellView.configure`), so the table's own inset is removed.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        return NSRect(x: 0, y: frame.minY, width: bounds.width, height: frame.height)
    }

    static func claim(for event: NSEvent) -> KeyClaim? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return nil }
        return KeyClaim.allCases.first { $0.input.unicodeScalars.first == scalar }
    }

    override func keyDown(with event: NSEvent) {
        if let claim = Self.claim(for: event), onKeyClaim?(claim) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenuForRow?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDraggingExited?()
    }
}

/// A Library row's surface: the pill (selection, keyboard focus, the open
/// document, hover, or the drop target) drawn by this view, never by the
/// table's own highlight. Flipped, like every chrome view.
final class LibraryRowView: NSTableRowView {
    var isOpenDocument = false { didSet { if oldValue != isOpenDocument { needsDisplay = true } } }
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    /// Headers fold on click and never hover or select.
    var isHeader = false
    private(set) var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// The pill this row paints right now (nil when idle).
    var currentBackground: SidebarViewController.RowBackground {
        SidebarViewController.rowBackground(
            isDropTarget: isDropTarget,
            isSelected: (!isHeader && isSelected) || isOpenDocument,
            isFocused: false,
            isHoveredOrHighlighted: !isHeader && isHovered)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isOpenDocument = false
        isDropTarget = false
    }

    /// The table's selection paint is off (`selectionHighlightStyle = .none`);
    /// the pill is the only mark.
    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        let background = currentBackground
        guard let color = background.backgroundColor else { return }
        let rect = bounds.insetBy(dx: 0, dy: 0.5)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: background.cornerRadius,
                     yRadius: background.cornerRadius).fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {}
}

/// A file or folder row: chevron slot, glyph, name. The name is one text field
/// that turns editable for the inline rename, so the swap moves nothing.
final class LibraryCellView: NSView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("library-row")

    /// One chevron view, reused across repaints: swapping views on a visible
    /// row reads as an accessory removal plus insertion.
    let chevron = NSImageView()
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")

    private var chevronLeading: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private var isPlaceholder = false

    /// Rename lifecycle, bound while the row edits. `onCommit` answers whether
    /// the name was accepted; a refusal keeps the field, so the row re-takes
    /// focus with the typed text.
    private var onCommit: ((String) -> Bool)?
    private var onCancel: (() -> Void)?
    private(set) var isEditing = false
    /// Set while a commit or cancel runs, so the end-editing callback that the
    /// focus change raises does not commit a second time.
    private var isFinishing = false

    /// Row insets: 8pt leading for a folder (its chevron slot), 23pt for a file
    /// so the glyphs line up past the slot; 7pt between glyph and name.
    static let folderLeading: CGFloat = ChalkMetrics.s(8)
    static let fileLeading: CGFloat = ChalkMetrics.s(23)
    static let iconTextPadding: CGFloat = ChalkMetrics.s(7)
    static let chevronSlotWidth: CGFloat = ChalkMetrics.s(8)
    /// One nesting step.
    static let indentUnit: CGFloat = ChalkMetrics.s(15)
    static let trailingInset: CGFloat = ChalkMetrics.s(8)
    static let iconConfiguration = NSImage.SymbolConfiguration(
        pointSize: ChalkMetrics.sidebarRowFontSize - 1.5, weight: .regular)
    static let chevronConfiguration = NSImage.SymbolConfiguration(
        pointSize: ChalkMetrics.s(8), weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        chevron.imageScaling = .scaleNone
        chevron.contentTintColor = .chalkTextFaint
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .chalkTextMuted
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.delegate = self
        label.focusRingType = .none
        addSubview(chevron)
        addSubview(icon)
        addSubview(label)
        chevronLeading = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.folderLeading)
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.fileLeading)
        NSLayoutConstraint.activate([
            chevronLeading,
            chevron.widthAnchor.constraint(equalToConstant: Self.chevronSlotWidth),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.iconTextPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Paint one row. Idempotent: runs on dequeue and on every state change.
    /// `chevronSymbol` nil hides the slot (files, the sentinel).
    func configure(name: String, symbol: String?, chevronSymbol: String?,
                   level: Int, prominent: Bool, isPlaceholder: Bool) {
        self.isPlaceholder = isPlaceholder
        let indent = CGFloat(max(0, level - 1)) * Self.indentUnit
        let isFolder = chevronSymbol != nil
        chevronLeading.constant = Self.folderLeading + indent
        iconLeading.constant = (isFolder ? Self.folderLeading + Self.chevronSlotWidth + Self.iconTextPadding
                                         : Self.fileLeading) + indent
        chevron.isHidden = !isFolder
        if let chevronSymbol {
            chevron.image = NSImage(systemSymbolName: chevronSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(Self.chevronConfiguration)
        }
        icon.isHidden = symbol == nil
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(Self.iconConfiguration)
        } else {
            icon.image = nil
        }
        if isPlaceholder {
            // The "Empty" sentinel: faint, glyph-less, and its text starts where
            // a file's glyph would.
            iconLeading.constant = Self.fileLeading + indent - Self.iconTextPadding
            label.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
            label.textColor = .chalkTextFaint
        } else {
            // Rows take the editor text ramp (body -> primary); the open
            // document and the selection brighten to primary and medium.
            label.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize,
                                     weight: prominent ? .medium : .regular)
            label.textColor = prominent ? .chalkTextPrimary : .chalkTextBody
        }
        // Never overwrite the text while the row edits: the field holds what
        // the user typed, which a refused name must keep.
        if !isEditing, label.stringValue != name { label.stringValue = name }
    }

    // MARK: - Inline rename

    /// Turn the name into a field, take the keyboard and preselect the base
    /// name. A row already editing keeps its text and only re-takes focus.
    func beginEditing(name: String, onCommit: @escaping (String) -> Bool, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        if !isEditing {
            isEditing = true
            label.stringValue = name
            label.isEditable = true
            label.isSelectable = true
            label.textColor = .chalkChromeFg
            label.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize, weight: .medium)
        }
        focusField()
    }

    /// Back to a label. `resign` hands focus to `next` (the table) so the
    /// keyboard does not go dark after a rename.
    func endEditing(focusReturningTo next: NSResponder?) {
        guard isEditing else { return }
        isEditing = false
        onCommit = nil
        onCancel = nil
        let hadFocus = label.currentEditor() != nil
        label.isEditable = false
        label.isSelectable = false
        if hadFocus, let window, let next {
            window.makeFirstResponder(next)
        }
    }

    private func focusField() {
        guard let window else { return }
        guard label.currentEditor() == nil else { return }
        window.makeFirstResponder(label)
        selectBaseName()
    }

    /// Select everything before the last dot, so typing replaces the name and
    /// keeps ".tex". A dotfile has no base to isolate: select it all.
    private func selectBaseName() {
        guard let editor = label.currentEditor() else { return }
        let name = label.stringValue
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            editor.selectAll(nil)
            return
        }
        editor.selectedRange = NSRange(location: 0, length: name.distance(from: name.startIndex, to: dot))
    }

    /// Esc cancels.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finish { onCancel?() }
        return true
    }

    /// Return commits; a refused name keeps the field. Losing focus commits a
    /// valid name and cancels an invalid one, so the user is never trapped.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditing, !isFinishing else { return }
        let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? NSOtherTextMovement
        let name = label.stringValue
        if movement == NSReturnTextMovement {
            var accepted = false
            finish { accepted = onCommit?(name) ?? true }
            if !accepted, isEditing {
                // The field editor has already resigned on Return; the row
                // keeps the typed text and takes the keyboard back.
                DispatchQueue.main.async { [weak self] in self?.focusField() }
            }
            return
        }
        finish {
            if FileNaming.validateRename(name, current: label.stringValue) == nil,
               onCommit?(name) == true {
                return
            }
            onCancel?()
        }
    }

    private func finish(_ body: () -> Void) {
        isFinishing = true
        body()
        isFinishing = false
    }

    #if DEBUG
    var isEditingForTesting: Bool { isEditing }
    #endif
}

/// An area header's trailing slot: the entry count at rest, the fold chevron
/// while the area is collapsed, never both. Cross-faded in a fixed frame so
/// folding never shifts the header's text.
final class HeaderTrailingSlot: NSView {
    private let count = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isCollapsed = false
    private var widthConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        count.font = .systemFont(ofSize: ChalkMetrics.sidebarCountFontSize)
        count.textColor = .chalkTextFaint
        count.alignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChalkMetrics.s(9), weight: .semibold))
        chevron.imageScaling = .scaleNone
        chevron.contentTintColor = .chalkTextFaint
        chevron.alphaValue = 0
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)
        addSubview(chevron)
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthConstraint,
            count.trailingAnchor.constraint(equalTo: trailingAnchor),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A zero count shows nothing at all: an empty area already says so with
    /// its "Empty" row, and "0" reads as a defect.
    func apply(count value: Int, collapsed: Bool) {
        count.stringValue = value > 0 ? "\(value)" : ""
        let changed = collapsed != isCollapsed
        isCollapsed = collapsed
        widthConstraint.constant = max(count.intrinsicContentSize.width,
                                       chevron.intrinsicContentSize.width)
        let show = { [self] in
            chevron.alphaValue = collapsed ? 1 : 0
            count.alphaValue = collapsed ? 0 : 1
        }
        guard changed, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            show()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ChalkMetrics.motionFast
            context.allowsImplicitAnimation = true
            show()
        }
    }

    #if DEBUG
    var stateForTesting: (count: String, showsChevron: Bool) {
        (count.alphaValue > 0.5 ? count.stringValue : "", chevron.alphaValue > 0.5)
    }
    #endif
}

/// A Location header: the area's name, a second line when the folder lost
/// sandbox access, and the trailing slot. Its row folds on click and carries
/// the Location's menu.
final class LibraryHeaderCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("library-header")

    let nameLabel = NSTextField(labelWithString: "")
    let secondaryLabel = NSTextField(labelWithString: "")
    let slot = HeaderTrailingSlot()
    private var nameTop: NSLayoutConstraint!

    static let leading: CGFloat = ChalkMetrics.s(8)
    static let trailing: CGFloat = ChalkMetrics.s(8)
    /// The first area sits against the chrome floor, which already separates
    /// it; the 22pt block of air belongs BETWEEN areas.
    static let firstTopMargin: CGFloat = ChalkMetrics.s(8)
    static let topMargin: CGFloat = ChalkMetrics.sidebarSectionTopMargin
    static let bottomMargin: CGFloat = ChalkMetrics.sidebarSectionBottomMargin
    static let nameFont = NSFont.systemFont(ofSize: ChalkMetrics.sectionHeaderFontSize, weight: .semibold)
    static let secondaryFont = NSFont.systemFont(ofSize: ChalkMetrics.sidebarCountFontSize)
    static let secondaryGap: CGFloat = 2

    /// The row height for a header: margins plus its one or two lines, so the
    /// table never self-sizes a row.
    static func height(isFirst: Bool, needsReauthorization: Bool) -> CGFloat {
        let top = isFirst ? firstTopMargin : topMargin
        var height = top + lineHeight(nameFont) + bottomMargin
        if needsReauthorization { height += secondaryGap + lineHeight(secondaryFont) }
        return ceil(height)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        nameLabel.font = Self.nameFont
        nameLabel.textColor = .chalkTextPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryLabel.font = Self.secondaryFont
        secondaryLabel.textColor = .chalkTextMuted
        secondaryLabel.maximumNumberOfLines = 1
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.isHidden = true
        slot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        addSubview(secondaryLabel)
        addSubview(slot)
        nameTop = nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.firstTopMargin)
        NSLayoutConstraint.activate([
            nameTop,
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leading),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: slot.leadingAnchor, constant: -ChalkMetrics.s(6)),
            secondaryLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            secondaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailing),
            secondaryLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: Self.secondaryGap),
            slot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailing),
            slot.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            slot.heightAnchor.constraint(equalTo: nameLabel.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(location: Location, isFirst: Bool, count: Int, collapsed: Bool) {
        nameLabel.stringValue = location.name
        nameTop.constant = isFirst ? Self.firstTopMargin : Self.topMargin
        if location.needsReauthorization {
            // Sandbox lost this folder (moved, deleted, or a pre-sandbox
            // bookmark): dim it and name the re-grant gesture.
            nameLabel.textColor = .chalkTextMuted
            secondaryLabel.stringValue = "No access \u{2014} right-click to grant"
            secondaryLabel.isHidden = false
        } else {
            nameLabel.textColor = .chalkTextPrimary
            secondaryLabel.isHidden = true
        }
        slot.apply(count: count, collapsed: collapsed)
    }
}
