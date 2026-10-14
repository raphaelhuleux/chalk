import UIKit
import ChalkKit

/// One outline palette (⌘P) row: indent, kind glyph, optional "Theorem 3" badge, title, and a
/// "return" key badge when selected. The persistent panel (⌘K) uses `OutlineTreeRowCell`.
final class OutlineRowCell: UITableViewCell {
    private let icon = UIImageView()
    private let badgeLabel = UILabel()
    private let titleLabel = UILabel()
    private let returnBadge = UILabel()
    private var iconLeading: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        registerForTraitChanges(UITraitCollection.chalkColorTraits) { (cell: Self, _: UITraitCollection) in
            cell.refreshBadgeEdge()
        }

        let selected = UIView()
        selected.backgroundColor = .chalkAccentSelection
        selected.layer.cornerRadius = ChalkMetrics.paletteRowRadius
        selected.layer.cornerCurve = .continuous
        selectedBackgroundView = selected

        icon.tintColor = .chalkChromeFgTertiary
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .systemFont(ofSize: ChalkMetrics.outlineBadgeFontSize, weight: .medium)
        badgeLabel.textColor = .chalkChromeFgSecondary
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        returnBadge.text = "return"
        returnBadge.font = .systemFont(ofSize: ChalkMetrics.s(10.5))
        returnBadge.textColor = .chalkChromeFgSecondary
        returnBadge.textAlignment = .center
        returnBadge.layer.borderWidth = 0.5
        returnBadge.layer.cornerRadius = ChalkMetrics.s(5)
        returnBadge.isHidden = true
        returnBadge.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(icon)
        contentView.addSubview(badgeLabel)
        contentView.addSubview(titleLabel)
        contentView.addSubview(returnBadge)
        iconLeading = icon.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: ChalkMetrics.s(10))
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: ChalkMetrics.s(16)),

            badgeLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: ChalkMetrics.s(9)),
            badgeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: ChalkMetrics.s(7)),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            returnBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -ChalkMetrics.s(10)),
            returnBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            returnBadge.widthAnchor.constraint(equalToConstant: ChalkMetrics.s(42)),
            returnBadge.heightAnchor.constraint(equalToConstant: ChalkMetrics.s(20)),
        ])
        refreshBadgeEdge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(item: OutlineItem, indent: Int, query: String) {
        iconLeading.constant = ChalkMetrics.s(10)
            + CGFloat(indent) * ChalkMetrics.outlineIndentUnit

        let symbol: String
        switch item.kind {
        case .heading: symbol = "number"
        case .callout: symbol = "function"
        case .figure: symbol = "photo"
        case .frame: symbol = "rectangle.on.rectangle"
        }
        icon.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ChalkMetrics.s(13), weight: .regular))

        badgeLabel.text = item.badge
        badgeLabel.isHidden = item.badge == nil

        let isTop = item.kind == .heading && item.level <= 1
        let baseWeight: UIFont.Weight = isTop ? .semibold : .regular
        let attributed = NSMutableAttributedString(
            string: item.title,
            attributes: [
                .foregroundColor: UIColor.chalkChromeFg,
                .font: UIFont.systemFont(
                    ofSize: ChalkMetrics.outlineRowFontSize, weight: baseWeight),
            ])
        // Accent highlight on a title prefix match.
        if !query.isEmpty, item.title.lowercased().hasPrefix(query.lowercased()),
           let range = item.title.range(of: item.title.prefix(query.count)) {
            attributed.addAttributes([
                .foregroundColor: UIColor.chalkAccent,
                .font: UIFont.systemFont(
                    ofSize: ChalkMetrics.outlineRowFontSize, weight: .semibold),
            ], range: NSRange(range, in: item.title))
        }
        titleLabel.attributedText = attributed
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        returnBadge.isHidden = !selected
    }

    private func refreshBadgeEdge() {
        returnBadge.layer.borderColor = UIColor.chalkKeyBadgeEdge
            .resolvedColor(with: traitCollection).cgColor
    }

    // The table is already inset from the card, so the pill spans the row minus a hair.
    override func layoutSubviews() {
        super.layoutSubviews()
        selectedBackgroundView?.frame = bounds.insetBy(dx: 0, dy: 1)
    }
}
