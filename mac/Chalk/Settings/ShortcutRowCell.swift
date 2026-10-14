import UIKit
import ChalkKit

/// Callbacks name their row by identity, never by index path: the table may have reloaded by the
/// time a callback fires (see `ShortcutRowIdentity`).
protocol ShortcutRowCellDelegate: AnyObject {
    func rowCell(
        _ cell: ShortcutRowCell,
        didEdit identity: ShortcutRowIdentity,
        trigger: String,
        replacement: String
    )
    func rowCell(
        _ cell: ShortcutRowCell,
        identity: ShortcutRowIdentity,
        didChange options: SnippetOptions
    )
    func rowCell(
        _ cell: ShortcutRowCell,
        identity: ShortcutRowIdentity,
        didSetEnabled isEnabled: Bool
    )
    /// The replacement editor grew or shrank; the table needs to re-measure.
    func rowCellDidChangeHeight(_ cell: ShortcutRowCell)
}

/// Column geometry shared by the rows and the column header so the labels sit over their columns.
/// Dimensions go through `ChalkMetrics.s` because Catalyst renders the iPad idiom at 0.77x.
enum ShortcutColumnLayout {
    /// The enable checkbox ahead of the first column; unlabelled in the header.
    static var checkboxWidth: CGFloat { ChalkMetrics.s(20) }
    static var gap: CGFloat { ChalkMetrics.s(10) }
    /// Fractions of the content layout guide's width.
    static let triggerWidthMultiplier: CGFloat = 0.20
    static let replacementWidthMultiplier: CGFloat = 0.48
}

/// A button whose hit area spans its whole column's height, so taps anywhere in a tall row's Options
/// column open the menu. Only the hit area grows: the frame's intrinsic height is what lets wrapped
/// chips grow the row, and horizontally it stays inside its column.
private final class ColumnHitButton: UIButton {
    /// Re-asserted every pass: each reassigned configuration brings back a corner radius, which only
    /// ever clips this text-only button.
    override func layoutSubviews() {
        super.layoutSubviews()
        clipsToBounds = false
        layer.cornerRadius = 0
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let host = superview else { return super.point(inside: point, with: event) }
        var column = convert(host.bounds, from: host) // the row's full height
        column.origin.x = bounds.minX
        column.size.width = bounds.width
        return column.contains(point)
    }
}

/// One row of the shortcuts table: enable checkbox, trigger, replacement, options chips. The
/// replacement is a non-scrolling UITextView whose intrinsic height drives the row.
final class ShortcutRowCell: UITableViewCell {
    static let reuseIdentifier = "ShortcutRowCell"

    weak var delegate: ShortcutRowCellDelegate?

    /// The row this cell currently renders, read back by the table instead of trusting index paths.
    private(set) var identity: ShortcutRowIdentity = .addRow

    private let enableButton = UIButton(type: .system)
    private let triggerField = UITextField()
    private let modifiedLabel = UILabel()
    private let replacementView = UITextView()
    private let chipsButton = ColumnHitButton()
    private var options = SnippetOptions()
    private var isEnabled = true
    /// Set during `prepareForReuse()`'s `endEditing(true)`, whose synchronous did-end-editing
    /// callbacks must not report the outgoing row's text as an edit.
    private var isBeingRecycled = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .chalkCardBackground
        selectionStyle = .none

        let mono = UIFont.monospacedSystemFont(ofSize: ChalkMetrics.s(12.5), weight: .regular)

        for field in [triggerField] {
            field.font = mono
            field.textColor = .chalkTextBody
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.focusEffect = nil // single-accent rule: no system blue halo
            field.delegate = self
        }
        triggerField.placeholder = "trigger"

        // Marks an edited built-in, which is why it offers Reset on swipe.
        modifiedLabel.text = "MODIFIED"
        modifiedLabel.font = .systemFont(ofSize: ChalkMetrics.s(8.5), weight: .semibold)
        modifiedLabel.textColor = .chalkTextFaint
        modifiedLabel.isHidden = true

        // Marker under the trigger, in a stack so a hidden marker costs no height.
        let triggerColumn = UIStackView(arrangedSubviews: [triggerField, modifiedLabel])
        triggerColumn.axis = .vertical
        // `.fill`, so the field stays tappable across the column's full width.
        triggerColumn.alignment = .fill
        triggerColumn.spacing = ChalkMetrics.s(1)

        replacementView.font = mono
        replacementView.textColor = .chalkTextBody
        replacementView.autocapitalizationType = .none
        replacementView.autocorrectionType = .no
        replacementView.spellCheckingType = .no
        replacementView.smartQuotesType = .no
        replacementView.smartDashesType = .no
        replacementView.focusEffect = nil
        replacementView.backgroundColor = .clear
        replacementView.isScrollEnabled = false // intrinsic height drives the row
        replacementView.textContainerInset = .zero
        replacementView.textContainer.lineFragmentPadding = 0
        replacementView.delegate = self

        // Configuration-based so wrapped chips feed the button's intrinsic height; a multi-line
        // `titleLabel` alone does not.
        let chipsTextInset = ChalkMetrics.s(3)
        var chips = UIButton.Configuration.plain()
        // The leading constraint pulls the button back by this inset, so text starts on the column edge.
        chips.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: chipsTextInset, bottom: 0, trailing: chipsTextInset)
        chips.titleLineBreakMode = .byWordWrapping
        chips.titleAlignment = .leading
        chips.baseForegroundColor = .chalkTextMuted // configuration tints the title
        // A plain configuration's `.dynamic` corner radius scales with the button and clips the
        // leading glyphs of wrapped lines. Square it off and don't clip.
        chips.cornerStyle = .fixed
        chips.background.cornerRadius = 0
        chipsButton.configuration = chips
        chipsButton.clipsToBounds = false
        chipsButton.layer.cornerRadius = 0
        chipsButton.titleLabel?.numberOfLines = 0
        chipsButton.contentHorizontalAlignment = .leading
        chipsButton.showsMenuAsPrimaryAction = true
        chipsButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.optionElements() ?? [])
            }
        ])

        enableButton.tintColor = .chalkAccent
        enableButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setEnabled(!self.isEnabled)
            self.delegate?.rowCell(self, identity: self.identity, didSetEnabled: self.isEnabled)
        }, for: .touchUpInside)

        for view in [enableButton, triggerColumn, replacementView, chipsButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        let guide = contentView.layoutMarginsGuide
        let gap = ShortcutColumnLayout.gap
        NSLayoutConstraint.activate([
            enableButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            enableButton.topAnchor.constraint(equalTo: guide.topAnchor),
            enableButton.widthAnchor.constraint(
                equalToConstant: ShortcutColumnLayout.checkboxWidth),

            triggerColumn.leadingAnchor.constraint(
                equalTo: enableButton.trailingAnchor, constant: gap),
            triggerColumn.topAnchor.constraint(equalTo: guide.topAnchor),
            triggerColumn.widthAnchor.constraint(
                equalTo: guide.widthAnchor,
                multiplier: ShortcutColumnLayout.triggerWidthMultiplier),

            replacementView.leadingAnchor.constraint(
                equalTo: triggerColumn.trailingAnchor, constant: gap),
            replacementView.topAnchor.constraint(equalTo: guide.topAnchor),
            replacementView.widthAnchor.constraint(
                equalTo: guide.widthAnchor,
                multiplier: ShortcutColumnLayout.replacementWidthMultiplier),

            chipsButton.leadingAnchor.constraint(
                equalTo: replacementView.trailingAnchor, constant: gap - chipsTextInset),
            chipsButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            chipsButton.topAnchor.constraint(equalTo: guide.topAnchor),
            // A minimum tap target: this menu is the only way to switch an option back on.
            chipsButton.heightAnchor.constraint(
                greaterThanOrEqualToConstant: ChalkMetrics.s(20)),

            // The row is as tall as its tallest column, and none of them clips.
            triggerColumn.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
            replacementView.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
            chipsButton.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// True while a field holds first responder. The table checks this before reloading, since
    /// `reloadData()` can detach the cell being typed into.
    var isEditingAnyField: Bool {
        triggerField.isFirstResponder || replacementView.isFirstResponder
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // The table can reload mid-edit (search filtering). Resign before reconfiguring, and
        // suppress the did-end-editing report that resign fires.
        isBeingRecycled = true
        endEditing(true)
        isBeingRecycled = false
    }

    func configure(
        identity: ShortcutRowIdentity,
        trigger: String,
        replacement: String,
        options: SnippetOptions,
        isEnabled: Bool,
        isModified: Bool
    ) {
        self.identity = identity
        triggerField.text = trigger
        replacementView.text = replacement
        self.options = options
        showChips(options)
        // The trailing add row has nothing to configure or switch off yet.
        let isPlaceholder = identity == .addRow
        chipsButton.isHidden = isPlaceholder
        enableButton.isHidden = isPlaceholder
        modifiedLabel.isHidden = !isModified
        setEnabled(isEnabled)
    }

    /// Close the options menu if open. UIKit exposes no handle on the menu's interaction, so it is
    /// found in `interactions`.
    func dismissOptionsMenu() {
        for interaction in chipsButton.interactions {
            (interaction as? UIContextMenuInteraction)?.dismissMenu()
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        let symbol = enabled ? "checkmark.square.fill" : "square"
        enableButton.setImage(UIImage(systemName: symbol), for: .normal)
        let color: UIColor = enabled ? .chalkTextBody : .chalkTextMuted
        triggerField.textColor = color
        replacementView.textColor = color
    }

    private func showChips(_ options: SnippetOptions) {
        let labels = options.chipLabels
        // An empty title would collapse the button, the only way back into the menu.
        let isEmpty = labels.isEmpty
        let color: UIColor = isEmpty ? .chalkTextFaint : .chalkTextMuted
        var config = chipsButton.configuration ?? .plain()
        config.baseForegroundColor = color
        config.attributedTitle = AttributedString(
            isEmpty ? "no options" : labels.joined(separator: " · "),
            attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: ChalkMetrics.s(11), weight: .medium),
                .foregroundColor: color,
            ]))
        chipsButton.configuration = config
    }

    private func optionElements() -> [UIMenuElement] {
        // The menu outlives this cell's binding to its row: each toggle saves and reloads the table,
        // which may rebind this cell while the menu stays up. So actions capture the row and options
        // here and never read them back off the cell, or one row's options land on another.
        let target = identity
        var pending = options // one shared box across this menu's actions

        func toggle(
            _ title: String,
            _ isOn: Bool,
            _ apply: @escaping (inout SnippetOptions) -> Void
        ) -> UIAction {
            let action = UIAction(title: title, state: isOn ? .on : .off) { [weak self] _ in
                apply(&pending)
                self?.reportOptions(pending, for: target)
            }
            // Set several options without the menu closing between taps.
            action.attributes.insert(.keepsMenuPresented)
            return action
        }

        // No Whole word toggle on a regex trigger, where the engine ignores it (`wholeWordApplies`).
        var behavior: [UIMenuElement] = [
            toggle("Auto-expand", pending.autoExpand) { $0.autoExpand.toggle() }
        ]
        if pending.wholeWordApplies {
            behavior.append(toggle("Whole word", pending.wholeWord) { $0.wholeWord.toggle() })
        }
        behavior.append(toggle("Line start", pending.lineStart) { $0.lineStart.toggle() })
        behavior.append(toggle("Regex trigger", pending.isRegex) { $0.isRegex.toggle() })

        return [
            UIMenu(title: "", options: .displayInline, children: [
                toggle("Math only", pending.mode == .math) { opts in
                    opts.mode = opts.mode == .math ? .any : .math
                },
                toggle("Text only", pending.mode == .text) { opts in
                    opts.mode = opts.mode == .text ? .any : .text
                },
            ]),
            UIMenu(title: "", options: .displayInline, children: behavior),
        ]
    }

    private func reportOptions(_ updated: SnippetOptions, for target: ShortcutRowIdentity) {
        // Repaint only if this cell still shows the menu's row; the write goes by identity either way.
        if identity == target {
            options = updated
            showChips(updated)
        }
        delegate?.rowCell(self, identity: target, didChange: updated)
    }

    private func reportEdit() {
        guard !isBeingRecycled else { return }
        delegate?.rowCell(
            self,
            didEdit: identity,
            trigger: triggerField.text ?? "",
            replacement: replacementView.text ?? ""
        )
    }
}

/// A section header with the section title and, on the first section only, the column labels. An
/// inset-grouped table gives header and cell the same width and margins, so `ShortcutColumnLayout`
/// lines the labels up with `ShortcutRowCell`'s columns.
final class ShortcutColumnsHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "ShortcutColumnsHeaderView"

    private let titleLabel = UILabel()
    private let columns = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()

        titleLabel.font = .systemFont(ofSize: ChalkMetrics.s(11), weight: .semibold)
        titleLabel.textColor = .chalkTextMuted

        let trigger = Self.columnLabel("Shortcut")
        let replacement = Self.columnLabel("Replacement")
        let options = Self.columnLabel("Options")
        for label in [trigger, replacement, options] {
            label.translatesAutoresizingMaskIntoConstraints = false
            columns.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: columns.topAnchor),
                label.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            ])
        }
        let gap = ShortcutColumnLayout.gap
        NSLayoutConstraint.activate([
            trigger.leadingAnchor.constraint(
                equalTo: columns.leadingAnchor,
                constant: ShortcutColumnLayout.checkboxWidth + gap),
            trigger.widthAnchor.constraint(
                equalTo: columns.widthAnchor,
                multiplier: ShortcutColumnLayout.triggerWidthMultiplier),
            replacement.leadingAnchor.constraint(
                equalTo: trigger.trailingAnchor, constant: gap),
            replacement.widthAnchor.constraint(
                equalTo: columns.widthAnchor,
                multiplier: ShortcutColumnLayout.replacementWidthMultiplier),
            options.leadingAnchor.constraint(
                equalTo: replacement.trailingAnchor, constant: gap),
            options.trailingAnchor.constraint(lessThanOrEqualTo: columns.trailingAnchor),
        ])

        // A stack so hidden column labels cost no height.
        let stack = UIStackView(arrangedSubviews: [titleLabel, columns])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = ChalkMetrics.s(5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let guide = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: guide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, showsColumns: Bool) {
        titleLabel.text = title
        columns.isHidden = !showsColumns
    }

    private static func columnLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: ChalkMetrics.s(10), weight: .semibold)
        label.textColor = .chalkTextMuted
        return label
    }
}

extension ShortcutRowCell: UITextFieldDelegate {
    func textFieldDidEndEditing(_ textField: UITextField) {
        reportEdit()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension ShortcutRowCell: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        delegate?.rowCellDidChangeHeight(self)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        reportEdit()
    }
}
