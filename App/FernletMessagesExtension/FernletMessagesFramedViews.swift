//
//  FernletMessagesFramedViews.swift
//  FernletMessagesExtension
//
//  The panel's framed pieces in UIKit (World Review Batch 4, `b4-msg-*`): the same shapes the app's
//  FernletUI primitives draw in SwiftUI — paper in a 2-point ink frame with a solid shadow, framed
//  icon tiles, a framed button with its darker bottom band — which this process cannot import.
//

import UIKit

/// A framed piece of the panel: `fill` in a 2-point ink frame, with a solid shadow `shadowDrop`
/// points down (none at zero), and a clipped ``contentView`` for what sits inside the frame.
///
/// The frame and the shadow are `CGColor`s, which do not follow Dark Mode by themselves, so they are
/// resolved against the view's own traits on every layout pass, and a Dark Mode or Increase Contrast
/// change asks for one. The fill is a dynamic `backgroundColor` and follows on its own. The frame is
/// drawn above the content (a layer's border sits over its sublayers), so a selected segment's fill
/// or a button's band never covers it.
class FernletMessagesFramedView: UIView {
    /// The clipped inside of the frame: subviews go here, so a fill reaching the corners stays round.
    let contentView = UIView()
    /// The face's colour.
    var fill: UIColor {
        didSet { backgroundColor = fill }
    }
    private let radius: CGFloat
    private let shadowTint: UIColor

    init(fill: UIColor, radius: CGFloat = FernletMessagesLook.cardRadius, shadowDrop: CGFloat = 3,
         shadowTint: UIColor = FernletMessagesLook.shadow) {
        self.fill = fill
        self.radius = radius
        self.shadowTint = shadowTint
        super.init(frame: .zero)
        backgroundColor = fill
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.borderWidth = FernletMessagesLook.frameWidth
        layer.shadowOpacity = shadowDrop > 0 ? 1 : 0
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: shadowDrop)
        contentView.layer.cornerRadius = radius
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        FernletMessagesLayout.pin(contentView, to: self)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: FernletMessagesFramedView, _: UITraitCollection) in view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.borderColor = FernletMessagesLook.ink.resolvedColor(with: traitCollection).cgColor
        layer.shadowColor = shadowTint.resolvedColor(with: traitCollection).cgColor
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }
}

/// One pixel icon that grows with the text size in steps (owner's form answer 42, 2026-10-25): `base`
/// points a key at the standard sizes and one step bigger at the accessibility sizes
/// (``FernletMessagesLook/pixel(_:for:)``), redrawn whenever the text size changes. A one-colour sprite
/// is drawn as a template and inked by `tintColor`; a coloured one (the fern, the bowl) keeps its colours.
final class FernletMessagesPixelIcon: UIImageView {
    private var sprite: FernletMessagesSprite
    private let base: CGFloat

    /// `sprite` at `base` points a key at the standard text sizes.
    init(sprite: FernletMessagesSprite, base: CGFloat) {
        self.sprite = sprite
        self.base = base
        super.init(frame: .zero)
        contentMode = .center
        isAccessibilityElement = false
        redraw()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (icon: FernletMessagesPixelIcon, _: UITraitCollection) in icon.redraw()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Swaps the icon, at the same size.
    func show(_ next: FernletMessagesSprite) {
        sprite = next
        redraw()
    }

    private func redraw() {
        let oneColour = Set(sprite.palette.values).count == 1
        image = sprite.image(pixel: FernletMessagesLook.pixel(base, for: traitCollection), template: oneColour)
    }
}

/// A framed square holding one pixel icon: the cards' bowl or dumbbell, the notice's, the ⓘ of a card
/// that can't be opened, and the picked card's check. Raised paper, no shadow, as FernletUI's
/// `FernletIconTile` draws it. The square grows with its icon, in the same step (form answer 42).
final class FernletMessagesIconTile: FernletMessagesFramedView {
    private let icon: FernletMessagesPixelIcon
    private let side: CGFloat
    private let base: CGFloat
    private var sideConstraints: [NSLayoutConstraint] = []

    /// A `side`-point tile showing `sprite` at `pixel` points a key (at the standard text sizes), on
    /// `fill`, a one-colour sprite inked in `ink`.
    init(side: CGFloat, sprite: FernletMessagesSprite, pixel: CGFloat, fill: UIColor = FernletMessagesLook.raised,
         ink: UIColor = FernletMessagesLook.iconInk) {
        icon = FernletMessagesPixelIcon(sprite: sprite, base: pixel)
        self.side = side
        base = pixel
        super.init(fill: fill, radius: side < 36 ? 6 : 9, shadowDrop: 0)
        icon.tintColor = ink
        icon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(icon)
        FernletMessagesLayout.pin(icon, to: contentView)
        translatesAutoresizingMaskIntoConstraints = false
        sideConstraints = [widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)]
        NSLayoutConstraint.activate(sideConstraints)
        isAccessibilityElement = false
        resize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (tile: FernletMessagesIconTile, _: UITraitCollection) in tile.resize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Swaps the icon. A one-colour sprite (the dumbbell, the ⓘ) is inked by the tile's ink token, so
    /// it stays visible on dark paper; a coloured one (the bowl) keeps its colours.
    func show(_ sprite: FernletMessagesSprite) {
        icon.show(sprite)
    }

    /// The square's side at the current text size.
    private func resize() {
        let grown = FernletMessagesLook.grown(side, base: base, for: traitCollection)
        sideConstraints.forEach { $0.constant = grown }
    }
}

/// The panel's buttons: the framed primary (Share, Review in Fernlet) and the quiet text button
/// (Browse your recipes), in the app's `ActionPillButtonStyle` framed shapes.
final class FernletMessagesButton: UIButton {
    /// Which of the two shapes.
    enum Kind {
        /// Accent fill in an ink frame, a darker band inside its bottom edge, a solid shadow.
        case primary
        /// Moss words on the page, no frame.
        case text
    }

    private let kind: Kind
    private let sprite: FernletMessagesSprite?
    private var title = ""

    /// A `kind` button, with `sprite` before its words when given.
    init(kind: Kind, sprite: FernletMessagesSprite? = nil) {
        self.kind = kind
        self.sprite = sprite
        super.init(frame: .zero)
        configurationUpdateHandler = { button in
            (button as? FernletMessagesButton)?.restyle()
        }
        restyle()
        // Its pixel icon grows with the words, in steps (form answer 42).
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (button: FernletMessagesButton, _: UITraitCollection) in button.setNeedsUpdateConfiguration()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Sets the button's words (its accessibility label too).
    func setTitle(_ title: String) {
        self.title = title
        setNeedsUpdateConfiguration()
    }

    private func restyle() {
        var configuration = UIButton.Configuration.plain()
        let ink = kind == .primary ? FernletMessagesLook.onAccent : FernletMessagesLook.link
        var words = AttributedString(title)
        words.font = kind == .primary ? FernletMessagesLook.button : FernletMessagesLook.textButton
        words.foregroundColor = ink
        configuration.attributedTitle = words
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.image = sprite?.image(pixel: FernletMessagesLook.pixel(2, for: traitCollection), template: true)
        configuration.imagePadding = 8
        configuration.baseForegroundColor = ink
        // The framed primary keeps its own ink while disabled, as the app's does: the faded face is
        // what says it is off (a disabled control is exempt from the contrast minimum).
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var kept = attributes
            kept.foregroundColor = ink
            return kept
        }
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in ink }
        configuration.contentInsets = kind == .primary
            ? NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 14, trailing: 20)
            : NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
        if kind == .primary { configuration.background.customView = primaryFace() }
        self.configuration = configuration
        alpha = isHighlighted ? 0.78 : 1
    }

    /// The primary's face: the accent (faded while disabled, as the app's framed primary fades) in an
    /// ink frame, with a 3-point band of shade inside its bottom edge.
    private func primaryFace() -> UIView {
        let enabled = isEnabled
        let fill = UIColor { @Sendable trait in
            FernletMessagesLook.accent.resolvedColor(with: trait).withAlphaComponent(enabled ? 1 : 0.55)
        }
        let face = FernletMessagesFramedView(fill: fill, radius: FernletMessagesLook.controlRadius,
                                             shadowDrop: 3, shadowTint: FernletMessagesLook.buttonShadow)
        let band = UIView()
        band.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        band.translatesAutoresizingMaskIntoConstraints = false
        face.contentView.addSubview(band)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: face.contentView.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: face.contentView.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: face.contentView.bottomAnchor),
            band.heightAnchor.constraint(equalToConstant: 3)
        ])
        face.isUserInteractionEnabled = false
        return face
    }
}

/// Auto Layout helpers the panel's views share.
enum FernletMessagesLayout {
    /// Pins `view`'s four edges to `container`'s, inset by `inset` points.
    static func pin(_ view: UIView, to container: UIView, inset: NSDirectionalEdgeInsets = .zero) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset.top),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset.leading),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset.trailing),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset.bottom)
        ])
    }

    /// A label in the panel's type: `font`, `colour`, wrapping, and growing with Dynamic Type.
    static func label(font: UIFont, colour: UIColor, lines: Int = 0) -> UILabel {
        let label = UILabel()
        label.font = font
        label.textColor = colour
        label.numberOfLines = lines
        label.adjustsFontForContentSizeCategory = true
        return label
    }
}
