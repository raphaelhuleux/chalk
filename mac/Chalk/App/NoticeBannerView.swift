import UIKit
import ChalkKit

/// The launch banner: "you crashed last time, may I have a report?".
///
/// An ask that is easy to ignore, hard to refuse, or in the way of typing
/// trains the user to dismiss it unread. So:
///
/// - It never takes first responder, nor do its buttons: stealing a keystroke
///   mid-sentence is worse than the bug it asks about.
/// - Its empty space is transparent to touches.
/// - Both buttons have identical weight: a greyed-out "No thanks" beside a
///   filled "Send a report" is a dark pattern.
/// - There is no "Not now": a deferral never counts as a refusal, so it could
///   be asked forever.
/// - Every way out answers exactly once, or one dismissal would burn two of
///   the three strikes.
final class NoticeBannerView: UIView {
    /// Composed rather than subclassed: ChalkGlassView is final, and the banner
    /// wants its own hit-testing anyway, which a subclass would have to fight.
    private let glass = ChalkGlassView(style: .glass,
                                       cornerRadius: ChalkMetrics.s(12),
                                       interactive: true)
    private let onPrimary: () -> Void
    private let onDecline: () -> Void
    private var isAnswered = false
    private var buttons: [UIButton] = []

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

        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: ChalkMetrics.s(12))
        label.textColor = .chalkTextBody
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var controls: [UIView] = [label]
        if let primaryTitle {
            let primary = Self.makeButton(title: primaryTitle)
            primary.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
            buttons.append(primary)
            controls.append(primary)
        }
        let decline = Self.makeButton(title: declineTitle)
        decline.addTarget(self, action: #selector(declineTapped), for: .touchUpInside)
        buttons.append(decline)
        controls.append(decline)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .chalkTextMuted
        close.addTarget(self, action: #selector(declineTapped), for: .touchUpInside)
        buttons.append(close)
        controls.append(close)

        let row = UIStackView(arrangedSubviews: controls)
        row.axis = .horizontal
        row.alignment = .center
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
    private static func makeButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: ChalkMetrics.s(12), weight: .semibold)
        button.setTitleColor(.chalkTextBody, for: .normal)
        return button
    }

    // MARK: - Never in the way

    override var canBecomeFirstResponder: Bool { false }

    /// Transparent except over its own controls. A hit that resolves to the
    /// banner, the glass, or the glass's content view means the touch landed on
    /// empty material, and that belongs to whatever is underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === glass || hit === glass.contentView { return nil }
        return hit
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
    var buttonsForTesting: [UIButton] { buttons }
    func pressPrimaryForTesting() { primaryTapped() }
    func pressDeclineForTesting() { declineTapped() }
    func dismissForTesting() { dismissByTimeout() }
    #endif
}
