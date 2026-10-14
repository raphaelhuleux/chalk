import UIKit
import ChalkKit

/// Inline rename: the row becomes a text field in place. It is a custom `UIContentConfiguration` so
/// the field keeps the row's exact font, insets and icon slot; an overlaid field would visibly jump.
/// The lifecycle lives on the controller because `renamingNode` is cell-registration input.
extension SidebarViewController {

    /// Enter edit mode on `node`. The "Empty" placeholder never renames.
    func beginRename(_ node: FileNode) {
        guard !Self.isEmptyPlaceholder(node) else { return }
        let previous = renamingNode
        renamingNode = node
        repaintRows(for: [previous, node])
    }

    /// Try to apply `name`. A rejected name keeps the editor open and shakes the row.
    func commitRename(_ name: String) {
        guard let node = renamingNode else { return }
        let current = node.url.lastPathComponent
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejection = FileNaming.validateRename(trimmed, current: current) {
            if rejection == .unchanged { cancelRename(); return }
            shakeRenameField()
            return
        }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        let started = moveFile(
            from: node.url, to: destination, actionName: "Rename", animated: true,
            completion: { [weak self] moved in
                // The move runs off the main thread, so a failure lands after the editor closed.
                guard !moved else { return }
                self?.showFileOpFailure("Couldn\u{2019}t rename \u{201C}\(node.url.lastPathComponent)\u{201D}.")
            })
        guard started else {
            // A sibling already owns the name, which `FileNaming` cannot see.
            shakeRenameField()
            return
        }
        // Close now, not when the async move lands, which replaces the row.
        renamingNode = nil
        repaintRows(for: [node])
    }

    /// Leave edit mode with the name unchanged.
    func cancelRename() {
        guard let node = renamingNode else { return }
        renamingNode = nil
        repaintRows(for: [node])
    }

    func shakeRenameField() {
        guard let node = renamingNode,
              let indexPath = dataSource.indexPath(for: node),
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 5, -3, 3, 0]
        shake.duration = ChalkMetrics.motionFast * 2
        cell.layer.add(shake, forKey: "chalk.rename.reject")
    }
}

/// The editing row's content: icon, then a text field where the label would be. Mirrors the
/// read-only row's font, colors and margins so the swap does not move anything.
struct SidebarRenameConfiguration: UIContentConfiguration {
    let node: FileNode
    let symbol: String
    /// Enter, or the field losing focus with a valid name.
    let onCommit: (String) -> Void
    /// Esc, or losing focus with a name that cannot be applied.
    let onCancel: () -> Void

    func makeContentView() -> UIView & UIContentView {
        SidebarRenameContentView(self)
    }

    func updated(for state: UIConfigurationState) -> SidebarRenameConfiguration { self }
}

final class SidebarRenameContentView: UIView, UIContentView, UITextFieldDelegate {
    private let icon = UIImageView()
    private let field = UITextField()
    private var appliedConfiguration: SidebarRenameConfiguration
    /// Set while committing, so `textFieldDidEndEditing` does not commit a second time.
    private var isFinishing = false

    var configuration: UIContentConfiguration {
        get { appliedConfiguration }
        set {
            guard let configuration = newValue as? SidebarRenameConfiguration else { return }
            appliedConfiguration = configuration
            apply(configuration)
        }
    }

    init(_ configuration: SidebarRenameConfiguration) {
        appliedConfiguration = configuration
        super.init(frame: .zero)

        icon.tintColor = .chalkChromeFgTertiary
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)

        field.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize, weight: .medium)
        field.textColor = .chalkChromeFg
        field.tintColor = .chalkChromeFg
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .done
        field.delegate = self

        let stack = UIStackView(arrangedSubviews: [icon, field])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = SidebarViewController.rowIconTextPadding
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let margins = SidebarViewController.rowMargins(isFile: !configuration.node.isDirectory)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margins.leading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margins.bottom),
        ])

        apply(configuration)
        // Take the keyboard as soon as the row exists and preselect the base name.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.field.becomeFirstResponder()
            self.selectBaseName()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func apply(_ configuration: SidebarRenameConfiguration) {
        icon.image = UIImage(
            systemName: configuration.symbol,
            withConfiguration: SidebarViewController.rowIconConfiguration)
        let name = configuration.node.url.lastPathComponent
        if field.text != name { field.text = name }
    }

    /// Select everything before the last dot, so typing replaces the name and
    /// keeps ".tex". A dotfile has no base to isolate: select it all.
    private func selectBaseName() {
        let name = appliedConfiguration.node.url.lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              let end = field.position(from: field.beginningOfDocument,
                                       offset: name.distance(from: name.startIndex, to: dot))
        else {
            field.selectAll(nil)
            return
        }
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: end)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        isFinishing = true
        appliedConfiguration.onCommit(textField.text ?? "")
        isFinishing = false
        return false
    }

    /// Esc cancels. Declared here because the field, not the controller, is first responder.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                      action: #selector(cancelEditing))]
    }

    @objc private func cancelEditing() {
        appliedConfiguration.onCancel()
    }

    /// Losing focus commits a valid name and cancels an invalid one, so the user is never trapped.
    func textFieldDidEndEditing(_ textField: UITextField) {
        guard !isFinishing else { return }
        let name = textField.text ?? ""
        if FileNaming.validateRename(
            name, current: appliedConfiguration.node.url.lastPathComponent) == nil {
            appliedConfiguration.onCommit(name)
        } else {
            appliedConfiguration.onCancel()
        }
    }
}

#if DEBUG
extension SidebarViewController {
    var isRenamingForTesting: Bool { renamingNode != nil }
}
#endif
