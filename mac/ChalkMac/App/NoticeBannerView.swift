import AppKit
import ChalkKit

/// The launch banner: "you crashed last time, may I have a report?".
///
/// An ask that is easy to ignore, hard to refuse, or in the way of typing
/// trains the user to dismiss it unread. So:
///
/// - It never takes first responder, nor do its buttons: stealing a keystroke
///   mid-sentence is worse than the bug it asks about.
/// - Its empty space is transparent to clicks.
/// - Both buttons have identical weight: a greyed-out "No thanks" beside a
///   filled "Send a report" is a dark pattern.
/// - There is no "Not now": a deferral never counts as a refusal, so it could
///   be asked forever.
/// - Every way out answers exactly once, or one dismissal would burn two of
///   the three strikes.
final class NoticeBannerView: FlippedView {
    /// Composed rather than subclassed: ChalkGlassView is final, and the banner
    /// wants its own hit-testing anyway.
    private let glass = ChalkGlassView(style: .glass, cornerRadius: ChalkMetrics.s(12), interactive: true)
    private let onPrimary: () -> Void
    private let onDecline: () -> Void
    private var isAnswered = false
    private var buttons: [NSButton] = []

    /// - Parameter primaryTitle: nil for a banner that only states a fact,
    ///   which then carries a close box and nothing else.
    init(message: String,
         primaryTitle: String?,
         declineTitle: String,
         onPrimary: @escaping () -> Void,
         onDecline: @escaping () -> Void) {
        self.onPrimary = onPrimary
        self.onDecline = onDecline
        super.init(frame: .zero)

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: ChalkMetrics.s(12))
        label.textColor = .chalkTextBody
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var controls: [NSView] = [label]
        if let primaryTitle {
            let primary = Self.makeButton(title: primaryTitle, action: #selector(primaryTapped))
            primary.target = self
            buttons.append(primary)
            controls.append(primary)
        }
        let decline = Self.makeButton(title: declineTitle, action: #selector(declineTapped))
        decline.target = self
        buttons.append(decline)
        controls.append(decline)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
                             target: self, action: #selector(declineTapped))
        close.title = ""
        close.isBordered = false
        close.contentTintColor = .chalkTextMuted
        close.refusesFirstResponder = true
        buttons.append(close)
        controls.append(close)

        let row = NSStackView(views: controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = ChalkMetrics.s(12)
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)

        let inset = ChalkMetrics.s(12)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: inset),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -inset),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Same font, same colour, same enabled state for accept and refuse.
    private static func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: ChalkMetrics.s(12), weight: .semibold)
        button.contentTintColor = .chalkTextBody
        button.refusesFirstResponder = true
        return button
    }

    // MARK: - Never in the way

    override var acceptsFirstResponder: Bool { false }

    /// Transparent except over its own controls. A hit that resolves to
    /// anything but a button means the click landed on empty material or the
    /// text, and that belongs to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        for button in buttons where hit === button || hit.isDescendant(of: button) { return hit }
        return nil
    }

    // MARK: - Answering

    @objc private func primaryTapped() { answer(onPrimary) }
    @objc private func declineTapped() { answer(onDecline) }

    /// The user walked away, or something else dismissed the banner. That is
    /// a refusal: if timing out cost nothing, the app could ask forever by
    /// making the ask easy to ignore.
    func dismissByTimeout() { answer(onDecline) }

    private func answer(_ handler: () -> Void) {
        guard !isAnswered else { return }
        isAnswered = true
        handler()
        removeFromSuperview()
    }

    // MARK: - Test seams

    #if DEBUG
    var buttonsForTesting: [NSButton] { buttons }
    func pressPrimaryForTesting() { primaryTapped() }
    func pressDeclineForTesting() { declineTapped() }
    func dismissForTesting() { dismissByTimeout() }
    #endif
}
