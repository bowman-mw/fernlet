//
//  FernletMessagesPanelPieces.swift
//  FernletMessagesExtension
//
//  The composer's and the received card's pieces (World Review Batch 4, `b4-msg-compact`,
//  `-expanded`, `-empty`, `-received`): the catalog card, Recipes | Workouts, the search field, the
//  notice, and the brand mark.
//

import UIKit

/// One recipe or workout in the composer's grid: framed raised paper with the pixel bowl or dumbbell
/// in a tile, the title, and its counts. The picked card gets a moss ring and a check (`b4-msg-compact`).
///
/// One accessibility element, as today's card button was: its title is the label, its counts the
/// hint, and "Selected" the value when picked.
final class FernletMessagesItemCard: UIControl {
    private let face = FernletMessagesFramedView(fill: FernletMessagesLook.raised)
    private let ring = CAShapeLayer()
    private let isPicked: Bool

    /// A card for `title` with `subtitle` (its counts) under it, drawn picked when `isPicked`.
    init(title: String, subtitle: String, sprite: FernletMessagesSprite, isPicked: Bool) {
        self.isPicked = isPicked
        super.init(frame: .zero)
        face.isUserInteractionEnabled = false
        face.translatesAutoresizingMaskIntoConstraints = false
        addSubview(face)
        FernletMessagesLayout.pin(face, to: self)
        let stack = contentStack(title: title, detail: subtitle, sprite: sprite)
        face.contentView.addSubview(stack)
        FernletMessagesLayout.pin(stack, to: face.contentView,
                                  inset: NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        heightAnchor.constraint(greaterThanOrEqualToConstant: 128).isActive = true
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 3
        ring.isHidden = !isPicked
        layer.addSublayer(ring)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        accessibilityHint = subtitle
        accessibilityValue = isPicked ? FernletMessagesCopy.selected : nil
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (card: FernletMessagesItemCard, _: UITraitCollection) in card.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.78 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let edge = ring.lineWidth / 2
        ring.path = UIBezierPath(roundedRect: bounds.insetBy(dx: -edge, dy: -edge),
                                 cornerRadius: FernletMessagesLook.cardRadius + edge).cgPath
        ring.strokeColor = FernletMessagesLook.ring.resolvedColor(with: traitCollection).cgColor
    }

    /// The tile (and the check when picked) over the title and the counts.
    private func contentStack(title: String, detail: String, sprite: FernletMessagesSprite) -> UIStackView {
        let top = UIStackView(arrangedSubviews: [FernletMessagesIconTile(side: 38, sprite: sprite, pixel: 2), UIView()])
        top.alignment = .top
        if isPicked { top.addArrangedSubview(checkBadge()) }
        let titleLabel = FernletMessagesLayout.label(font: FernletMessagesLook.cardTitle, colour: FernletMessagesLook.text)
        titleLabel.text = title
        let detailLabel = FernletMessagesLayout.label(font: FernletMessagesLook.cardDetail, colour: FernletMessagesLook.dim)
        detailLabel.text = detail
        let stack = UIStackView(arrangedSubviews: [top, titleLabel, detailLabel, UIView()])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(10, after: top)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        return stack
    }

    /// The picked card's check: the accent in a small ink frame, the tick in the on-accent ink, growing
    /// with the text in steps.
    private func checkBadge() -> UIView {
        FernletMessagesIconTile(side: 26, sprite: .check, pixel: 2, fill: FernletMessagesLook.accent,
                                ink: FernletMessagesLook.onAccent)
    }
}

/// Recipes | Workouts as the app's framed segmented control (`FernletSegmentedPicker`): raised paper
/// in an ink frame with an ink rule between segments, the chosen one in the accent. Side by side, or
/// one above the other at accessibility text sizes so neither word breaks.
final class FernletMessagesSegmentedControl: UIView {
    /// The chosen segment's index.
    private(set) var selectedIndex = 0
    /// Called with the new index when the person picks the other segment.
    var onChange: ((Int) -> Void)?
    private let face = FernletMessagesFramedView(fill: FernletMessagesLook.ink, radius: FernletMessagesLook.controlRadius,
                                                 shadowDrop: 2)
    private let stack = UIStackView()
    private var segments: [UIButton] = []
    private let titles: [String]

    /// A control with one segment per title, the first chosen.
    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        face.translatesAutoresizingMaskIntoConstraints = false
        addSubview(face)
        FernletMessagesLayout.pin(face, to: self)
        stack.distribution = .fillEqually
        stack.spacing = FernletMessagesLook.frameWidth
        stack.translatesAutoresizingMaskIntoConstraints = false
        face.contentView.addSubview(stack)
        FernletMessagesLayout.pin(stack, to: face.contentView)
        for index in titles.indices {
            let segment = UIButton(type: .custom)
            segment.addAction(UIAction { [weak self] _ in self?.pick(index) }, for: .touchUpInside)
            segment.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // Restyled on every state and trait change, so the words follow Dynamic Type.
            segment.configurationUpdateHandler = { [weak self] button in self?.style(button, at: index) }
            segments.append(segment)
            stack.addArrangedSubview(segment)
        }
        applyAxis()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (control: FernletMessagesSegmentedControl, _: UITraitCollection) in control.applyAxis()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows `index` as chosen without calling ``onChange``.
    func select(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        selectedIndex = index
        segments.forEach { $0.setNeedsUpdateConfiguration() }
    }

    private func pick(_ index: Int) {
        guard index != selectedIndex else { return }
        select(index)
        onChange?(index)
    }

    private func applyAxis() {
        stack.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
    }

    /// One segment: the words in DM Sans semibold, the accent behind the chosen one.
    private func style(_ segment: UIButton, at index: Int) {
        guard titles.indices.contains(index) else { return }
        let chosen = index == selectedIndex
        var configuration = UIButton.Configuration.plain()
        var words = AttributedString(titles[index])
        words.font = FernletMessagesLook.segment
        let ink = chosen ? FernletMessagesLook.onAccent : FernletMessagesLook.text
        words.foregroundColor = ink
        configuration.attributedTitle = words
        configuration.baseForegroundColor = ink
        configuration.titleAlignment = .center
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 4, bottom: 9, trailing: 4)
        configuration.background.backgroundColor = chosen ? FernletMessagesLook.accent : FernletMessagesLook.raised
        configuration.background.cornerRadius = 0
        segment.configuration = configuration
        segment.accessibilityTraits = chosen ? [.button, .selected] : .button
    }
}

/// The expanded composer's search: the framed field with the pixel magnifier (`b4-msg-expanded`).
final class FernletMessagesSearchField: FernletMessagesFramedView {
    /// The text field itself; the controller listens to its edits.
    let textField = UITextField()

    /// An empty field; the controller sets its prompt for the chosen kind.
    init() {
        super.init(fill: FernletMessagesLook.raised, radius: FernletMessagesLook.controlRadius, shadowDrop: 0)
        let icon = FernletMessagesPixelIcon(sprite: .search, base: 2)
        icon.tintColor = FernletMessagesLook.iconInk
        icon.setContentHuggingPriority(.required, for: .horizontal)
        textField.font = FernletMessagesLook.field
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = FernletMessagesLook.text
        textField.tintColor = FernletMessagesLook.link
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.accessibilityTraits = textField.accessibilityTraits.union(.searchField)
        let row = UIStackView(arrangedSubviews: [icon, textField])
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        FernletMessagesLayout.pin(row, to: contentView,
                                  inset: NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
        heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The prompt in the field, in the secondary ink so it reads as a prompt in light and dark mode.
    func setPlaceholder(_ text: String) {
        textField.attributedPlaceholder = NSAttributedString(
            string: text, attributes: [.foregroundColor: FernletMessagesLook.dim, .font: FernletMessagesLook.field])
    }
}

/// A framed paper card holding one line, with a pixel icon in a tile when given: the empty catalog's
/// "Open Fernlet to prepare items for Messages." (`b4-msg-empty`) and the received card's counts
/// (`b4-msg-received`).
final class FernletMessagesNoticeCard: FernletMessagesFramedView {
    /// The words.
    let label: UILabel
    private let tile: FernletMessagesIconTile?

    /// A card with `sprite` in a 40-point tile beside the words, or the words alone when nil.
    init(sprite: FernletMessagesSprite?, font: UIFont, colour: UIColor) {
        label = FernletMessagesLayout.label(font: font, colour: colour)
        tile = sprite.map { FernletMessagesIconTile(side: 40, sprite: $0, pixel: 2) }
        super.init(fill: FernletMessagesLook.paper)
        let pieces: [UIView?] = [tile, label]
        let row = UIStackView(arrangedSubviews: pieces.compactMap { $0 })
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        FernletMessagesLayout.pin(row, to: contentView,
                                  inset: NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows `text`, with `sprite` in the tile when the card has one.
    func show(_ text: String, sprite: FernletMessagesSprite? = nil) {
        label.text = text
        guard let sprite, let tile else { return }
        tile.show(sprite)
    }
}

/// The pixel fern and "Fernlet" above the title (`b4-msg-opening`), replacing "⌁  FERNLET".
final class FernletMessagesBrandView: UIStackView {
    /// The fern, then the name in the link moss, left-aligned.
    init() {
        let fern = FernletMessagesPixelIcon(sprite: .fern, base: 2)
        fern.setContentHuggingPriority(.required, for: .horizontal)
        let name = FernletMessagesLayout.label(font: FernletMessagesLook.brand, colour: FernletMessagesLook.link, lines: 1)
        name.text = FernletMessagesCopy.brandName
        super.init(frame: .zero)
        addArrangedSubview(fern)
        addArrangedSubview(name)
        addArrangedSubview(UIView())
        spacing = 6
        alignment = .center
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        super.init(frame: .zero)
    }
}
