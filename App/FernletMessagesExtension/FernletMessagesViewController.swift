import FernletExchange
import Messages
import UIKit

/// A bounded recipe/workout composer. It reads only the App Group catalog and independently
/// decodes every received envelope instead of trusting the visible message card.
final class FernletMessagesViewController: MSMessagesAppViewController, UISearchBarDelegate {
    /// Which half of the App Group catalog the composer is showing.
    ///
    /// The `Int` raw values are the `UISegmentedControl` indices, so the segment order and this
    /// declaration order are one fact, not two.
    private enum CatalogMode: Int {
        case recipes
        case workouts
    }

    /// The composer's colours, spelled out in `UIColor` rather than read from the app's design
    /// tokens: an app extension is a separate process with no access to the host's asset catalog,
    /// and a missing token here would render as black-on-black rather than fail loudly.
    private enum Palette {
        static let ink = UIColor(red: 0.24, green: 0.18, blue: 0.12, alpha: 1)
        static let moss = UIColor(red: 0.27, green: 0.41, blue: 0.23, alpha: 1)
        static let paper = UIColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1)
        static let card = UIColor(red: 0.99, green: 0.97, blue: 0.92, alpha: 1)
        static let sage = UIColor(red: 0.79, green: 0.85, blue: 0.73, alpha: 1)
        static let muted = UIColor(red: 0.36, green: 0.42, blue: 0.47, alpha: 1)
        static let line = UIColor(red: 0.24, green: 0.18, blue: 0.12, alpha: 0.16)
    }

    private let brandLabel = UILabel()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let modeControl = UISegmentedControl(
        items: [FernletMessagesCopy.modeRecipes, FernletMessagesCopy.modeWorkouts]
    )
    private let searchBar = UISearchBar()
    private let previewLabel = UILabel()
    private let headerStack = UIStackView()
    private let itemStack = UIStackView()
    private let browseButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let reviewButton = UIButton(type: .system)
    private var catalog: FernletMessagesCatalog?
    private var selectedRecipeID: UUID?
    private var selectedWorkoutID: UUID?
    private var receivedRecipe: RecipeExchangePacket?
    private var receivedWorkout: FernletMessagesWorkoutInboxRecord?
    private var isShowingReceivedItem = false
    private var catalogUnavailableMessage: String?

    private var catalogMode: CatalogMode {
        CatalogMode(rawValue: modeControl.selectedSegmentIndex) ?? .recipes
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        reloadCatalog()
        renderComposer()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        reloadCatalog()
        guard let message = conversation.selectedMessage else {
            isShowingReceivedItem = false
            renderComposer()
            return
        }
        showReceivedItem(from: message)
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        showReceivedItem(from: message)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        guard !isShowingReceivedItem else { return }
        renderComposer()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard presentationStyle == .expanded, !isShowingReceivedItem else { return }
        renderComposer()
    }

    @objc private func modeChanged() {
        searchBar.text = ""
        renderComposer()
    }

    @objc private func browseItems() {
        requestPresentationStyle(.expanded)
    }

    @objc private func insertSelectedItem() {
        switch catalogMode {
        case .recipes: insertSelectedRecipe()
        case .workouts: insertSelectedWorkout()
        }
    }

    @objc private func openReceivedItemInFernlet() {
        if let receivedRecipe {
            openRecipeInFernlet(receivedRecipe)
        } else if let receivedWorkout {
            openWorkoutInFernlet(receivedWorkout)
        } else {
            statusLabel.text = FernletMessagesCopy.prepareItemFailed
        }
    }

    private func configureView() {
        view.backgroundColor = Palette.paper
        configureLabels()
        configureButtons()
        configureHeader()
        let contentStack = UIStackView(arrangedSubviews: [
            headerStack, statusLabel, modeControl, searchBar, previewLabel, itemStack, browseButton, reviewButton
        ])
        contentStack.axis = .vertical
        contentStack.spacing = 14
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.indicatorStyle = .black
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate(scrollConstraints(for: scrollView, contentStack: contentStack))
    }

    private func configureLabels() {
        brandLabel.text = FernletMessagesCopy.brand
        brandLabel.font = .preferredFont(forTextStyle: .caption1)
        brandLabel.textColor = Palette.moss
        brandLabel.adjustsFontForContentSizeCategory = true
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = Palette.ink
        titleLabel.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = Palette.muted
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        previewLabel.font = .preferredFont(forTextStyle: .footnote)
        previewLabel.textColor = Palette.moss
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.numberOfLines = 0
        modeControl.selectedSegmentIndex = CatalogMode.recipes.rawValue
        modeControl.selectedSegmentTintColor = Palette.sage
        modeControl.backgroundColor = Palette.card
        modeControl.setTitleTextAttributes([.foregroundColor: Palette.ink], for: .normal)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        itemStack.axis = .vertical
        itemStack.spacing = 10
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.tintColor = Palette.moss
        searchBar.searchTextField.backgroundColor = Palette.card
        searchBar.searchTextField.textColor = Palette.ink
        searchBar.searchTextField.layer.cornerRadius = 14
        searchBar.searchTextField.layer.masksToBounds = true
    }

    private func configureButtons() {
        browseButton.addTarget(self, action: #selector(browseItems), for: .touchUpInside)
        browseButton.configuration = textButtonConfiguration(title: FernletMessagesCopy.browseLibrary)
        browseButton.accessibilityHint = FernletMessagesCopy.browseHint
        insertButton.addTarget(self, action: #selector(insertSelectedItem), for: .touchUpInside)
        insertButton.accessibilityHint = FernletMessagesCopy.insertHint
        reviewButton.configuration = filledButtonConfiguration(title: FernletMessagesCopy.reviewInFernlet)
        reviewButton.addTarget(self, action: #selector(openReceivedItemInFernlet), for: .touchUpInside)
        reviewButton.accessibilityHint = FernletMessagesCopy.reviewHint
    }

    private func configureHeader() {
        let titleStack = UIStackView(arrangedSubviews: [brandLabel, titleLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 3
        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(insertButton)
        headerStack.axis = .horizontal
        headerStack.alignment = .top
        headerStack.spacing = 12
        insertButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func textButtonConfiguration(title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = Palette.moss
        return configuration
    }

    private func filledButtonConfiguration(title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = Palette.moss
        configuration.baseForegroundColor = Palette.paper
        configuration.cornerStyle = .capsule
        return configuration
    }

    private func scrollConstraints(for scrollView: UIScrollView, contentStack: UIStackView) -> [NSLayoutConstraint] {
        [
            scrollView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ]
    }

    private func reloadCatalog() {
        guard let directory = FernletMessagesCatalogFileStore.productionDirectory() else {
            catalog = nil
            catalogUnavailableMessage = FernletMessagesCopy.sharedStorageUnavailable
            return
        }
        do {
            catalog = try FernletMessagesCatalogFileStore(directory: directory).read()
            catalogUnavailableMessage = nil
        } catch {
            catalog = nil
            catalogUnavailableMessage = FernletMessagesCopy.catalogUnreadable
        }
    }

    private func renderComposer() {
        isShowingReceivedItem = false
        receivedRecipe = nil
        receivedWorkout = nil
        configureComposerVisibility()
        guard let catalog else {
            titleLabel.text = composerTitle
            statusLabel.text = catalogUnavailableMessage ?? FernletMessagesCopy.emptyCatalog
            statusLabel.isHidden = false
            previewLabel.text = ""
            previewLabel.isHidden = true
            insertButton.isHidden = true
            renderButtons([])
            return
        }
        switch catalogMode {
        case .recipes: renderRecipes(in: catalog)
        case .workouts: renderWorkouts(in: catalog)
        }
    }

    private func configureComposerVisibility() {
        modeControl.isHidden = false
        searchBar.isHidden = presentationStyle != .expanded
        itemStack.isHidden = false
        browseButton.isHidden = presentationStyle == .expanded
        insertButton.isHidden = false
        reviewButton.isHidden = true
        statusLabel.isHidden = true
        searchBar.placeholder = catalogMode == .recipes
            ? FernletMessagesCopy.searchRecipesPlaceholder
            : FernletMessagesCopy.searchWorkoutsPlaceholder
        // Two whole sentences, not "Browse your %@": the noun cannot be spliced into a
        // possessive in every language, and a translator cannot reorder around the splice.
        browseButton.configuration = textButtonConfiguration(
            title: catalogMode == .recipes ? FernletMessagesCopy.browseRecipes : FernletMessagesCopy.browseWorkouts
        )
        insertButton.configuration = filledButtonConfiguration(title: FernletMessagesCopy.share)
    }

    private func renderRecipes(in catalog: FernletMessagesCatalog) {
        let entries = visibleRecipeEntries(in: catalog)
        titleLabel.text = FernletMessagesCopy.shareRecipeTitle
        setPreviewText(recipePreviewText(for: selectedRecipeEntry()))
        insertButton.isEnabled = selectedRecipeEntry() != nil
        renderButtons(entries.map(recipeButton(for:)))
    }

    private func renderWorkouts(in catalog: FernletMessagesCatalog) {
        let entries = visibleWorkoutEntries(in: catalog)
        titleLabel.text = FernletMessagesCopy.shareWorkoutTitle
        setPreviewText(workoutPreviewText(for: selectedWorkoutEntry()))
        insertButton.isEnabled = selectedWorkoutEntry() != nil
        renderButtons(entries.map(workoutButton(for:)))
    }

    private var composerTitle: String {
        catalogMode == .recipes
            ? FernletMessagesCopy.shareFernletRecipeTitle
            : FernletMessagesCopy.shareFernletWorkoutTitle
    }

    private func renderButtons(_ buttons: [UIButton]) {
        for view in itemStack.arrangedSubviews.prefix(FernletMessagesCatalogLimits.maxRecipes) {
            itemStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let cards = Array(buttons.prefix(FernletMessagesCatalogLimits.maxRecipes))
        for index in stride(from: 0, to: cards.count, by: 2) {
            itemStack.addArrangedSubview(cardRow(first: cards[index], second: button(at: index + 1, in: cards)))
        }
    }

    private func cardRow(first: UIButton, second: UIButton?) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.spacing = 10
        row.addArrangedSubview(first)
        if let second {
            row.addArrangedSubview(second)
        } else {
            let spacer = UIView()
            spacer.isUserInteractionEnabled = false
            row.addArrangedSubview(spacer)
        }
        return row
    }

    private func button(at index: Int, in buttons: [UIButton]) -> UIButton? {
        guard index >= 0, index < buttons.count else { return nil }
        return buttons[index]
    }

    private func visibleRecipeEntries(in catalog: FernletMessagesCatalog) -> [FernletMessagesRecipeCatalogEntry] {
        if presentationStyle == .expanded {
            return FernletMessagesRecipePicker.entries(matching: searchBar.text ?? "", in: catalog)
        }
        return FernletMessagesRecipePicker.compactEntries(in: catalog, lastSelectedRecipeID: lastSelectedRecipeID())
    }

    private func visibleWorkoutEntries(in catalog: FernletMessagesCatalog) -> [FernletMessagesWorkoutCatalogEntry] {
        if presentationStyle == .expanded {
            return FernletMessagesWorkoutPicker.entries(matching: searchBar.text ?? "", in: catalog)
        }
        return FernletMessagesWorkoutPicker.compactEntries(in: catalog)
    }

    private func recipeButton(for entry: FernletMessagesRecipeCatalogEntry) -> UIButton {
        let isSelected = entry.packet.originContentID == selectedRecipeID
        let summary = recipeSummary(for: entry.packet)
        let subtitle = entry.packet.includesNotes
            ? FernletMessagesCopy.recipeSubtitleWithNote(summary: summary)
            : summary
        let button = catalogButton(title: entry.packet.recipe.name, subtitle: subtitle,
                                   symbol: "fork.knife", isSelected: isSelected)
        button.addAction(UIAction { [weak self] _ in self?.selectRecipe(entry.packet.originContentID) }, for: .touchUpInside)
        return button
    }

    private func workoutButton(for entry: FernletMessagesWorkoutCatalogEntry) -> UIButton {
        let isSelected = entry.packet.originContentID == selectedWorkoutID
        let button = catalogButton(title: entry.card.title, subtitle: workoutSummary(for: entry),
                                   symbol: "figure.strengthtraining.traditional", isSelected: isSelected)
        button.addAction(UIAction { [weak self] _ in self?.selectWorkout(entry.packet.originContentID) }, for: .touchUpInside)
        return button
    }

    private func catalogButton(title: String, subtitle: String, symbol: String, isSelected: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.backgroundColor = isSelected ? Palette.sage : Palette.card
        button.layer.cornerRadius = 18
        button.layer.borderWidth = isSelected ? 2 : 1
        button.layer.borderColor = (isSelected ? Palette.moss : Palette.line).cgColor
        let imageView = UIImageView(image: UIImage(systemName: symbol))
        imageView.tintColor = Palette.moss
        imageView.contentMode = .scaleAspectFit
        let titleLabel = catalogTitleLabel(text: title)
        let subtitleLabel = catalogSubtitleLabel(text: subtitle)
        button.addSubview(imageView)
        button.addSubview(titleLabel)
        button.addSubview(subtitleLabel)
        [imageView, titleLabel, subtitleLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate(catalogButtonConstraints(
            imageView: imageView, titleLabel: titleLabel, subtitleLabel: subtitleLabel, in: button
        ))
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 138).isActive = true
        button.accessibilityLabel = title
        button.accessibilityHint = subtitle
        button.accessibilityValue = isSelected ? FernletMessagesCopy.selected : ""
        return button
    }

    private func catalogTitleLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = Palette.ink
        label.numberOfLines = 2
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func catalogSubtitleLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = Palette.muted
        label.numberOfLines = 2
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func catalogButtonConstraints(
        imageView: UIImageView, titleLabel: UILabel, subtitleLabel: UILabel, in button: UIButton
    ) -> [NSLayoutConstraint] {
        [
            imageView.topAnchor.constraint(equalTo: button.topAnchor, constant: 14),
            imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            imageView.widthAnchor.constraint(equalToConstant: 30),
            imageView.heightAnchor.constraint(equalToConstant: 30),
            subtitleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -12),
            titleLabel.leadingAnchor.constraint(equalTo: subtitleLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -4)
        ]
    }

    private func selectRecipe(_ id: UUID) {
        selectedRecipeID = id
        UserDefaults.standard.set(id.uuidString, forKey: "FernletMessages.lastRecipeID")
        renderComposer()
    }

    private func selectWorkout(_ id: UUID) {
        selectedWorkoutID = id
        renderComposer()
    }

    private func selectedRecipeEntry() -> FernletMessagesRecipeCatalogEntry? {
        guard let selectedRecipeID, let catalog else { return nil }
        return catalog.recipes.first(where: { $0.packet.originContentID == selectedRecipeID })
    }

    private func selectedWorkoutEntry() -> FernletMessagesWorkoutCatalogEntry? {
        guard let selectedWorkoutID, let catalog else { return nil }
        return catalog.workouts.first(where: { $0.packet.originContentID == selectedWorkoutID })
    }

    private func lastSelectedRecipeID() -> UUID? {
        guard let text = UserDefaults.standard.string(forKey: "FernletMessages.lastRecipeID") else { return nil }
        return UUID(uuidString: text)
    }

    private func recipePreviewText(for entry: FernletMessagesRecipeCatalogEntry?) -> String {
        guard let entry else { return "" }
        guard entry.packet.includesNotes else {
            return FernletMessagesCopy.recipePreviewWithoutNote(summary: recipeSummary(for: entry.packet))
        }
        let note = entry.packet.recipe.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty
            ? recipeSummary(for: entry.packet)
            : FernletMessagesCopy.recipeNotePreview(note: String(note.prefix(120)))
    }

    private func workoutPreviewText(for entry: FernletMessagesWorkoutCatalogEntry?) -> String {
        guard let entry else { return "" }
        return workoutSummary(for: entry)
    }

    private func setPreviewText(_ text: String) {
        previewLabel.text = text
        previewLabel.isHidden = text.isEmpty
    }

    /// Three separately plural-ruled counts joined by punctuation. One key holding all three
    /// would give a translator a single form for three independent plurals.
    private func recipeSummary(for packet: RecipeExchangePacket) -> String {
        [
            FernletMessagesCopy.servingCount(packet.recipe.servings),
            FernletMessagesCopy.ingredientCount(packet.recipe.ingredients.count),
            FernletMessagesCopy.stepCount(packet.recipe.steps?.count ?? 0)
        ].joined(separator: " · ")
    }

    private func workoutSummary(for entry: FernletMessagesWorkoutCatalogEntry) -> String {
        "\(entry.dayKey) · \(FernletMessagesCopy.workoutCount(entry.packet.plan.sessionCount))"
    }

    private func insertSelectedRecipe() {
        guard let conversation = activeConversation, let entry = selectedRecipeEntry() else {
            showComposerStatus(FernletMessagesCopy.chooseRecipe)
            return
        }
        do {
            let envelope = try ExchangeMessageEnvelope(recipe: entry.packet)
            insert(message: try message(for: envelope, layout: recipeLayout(for: entry.packet)),
                   into: conversation, success: FernletMessagesCopy.recipeInserted)
        } catch {
            showComposerStatus(FernletMessagesCopy.recipeTooLarge)
        }
    }

    private func insertSelectedWorkout() {
        guard let conversation = activeConversation, let entry = selectedWorkoutEntry() else {
            showComposerStatus(FernletMessagesCopy.chooseWorkout)
            return
        }
        do {
            let envelope = try ExchangeMessageEnvelope(workoutPlan: entry.packet, scheduledStartDayKey: entry.dayKey)
            insert(message: try message(for: envelope, layout: workoutLayout(for: entry)),
                   into: conversation, success: FernletMessagesCopy.workoutInserted)
        } catch {
            showComposerStatus(FernletMessagesCopy.workoutTooLarge)
        }
    }

    private func message(for envelope: ExchangeMessageEnvelope, layout: MSMessageTemplateLayout) throws -> MSMessage {
        let message = MSMessage()
        message.url = try envelope.messageURL()
        message.layout = layout
        message.summaryText = FernletMessagesCopy.messageSummary(title: envelope.card.title)
        return message
    }

    private func insert(message: MSMessage, into conversation: MSConversation, success: String) {
        conversation.insert(message) { [weak self] error in
            self?.showComposerStatus(error == nil ? success : FernletMessagesCopy.insertFailed)
        }
    }

    private func showComposerStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }

    private func recipeLayout(for packet: RecipeExchangePacket) -> MSMessageTemplateLayout {
        let layout = MSMessageTemplateLayout()
        layout.image = recipePlaceholderImage()
        layout.caption = packet.recipe.name
        layout.subcaption = recipeSummary(for: packet)
        layout.trailingCaption = packet.includesNotes ? FernletMessagesCopy.cardNotesIncluded : FernletMessagesCopy.cardRecipe
        return layout
    }

    /// Local, high-resolution cards; Messages never fetches or exposes private food photos.
    private func recipePlaceholderImage() -> UIImage {
        placeholderImage(symbol: "fork.knife", label: FernletMessagesCopy.recipeWordmark)
    }

    private func workoutPlaceholderImage() -> UIImage {
        placeholderImage(symbol: "dumbbell.fill", label: FernletMessagesCopy.workoutWordmark)
    }

    private func placeholderImage(symbol: String, label: String) -> UIImage {
        let size = CGSize(width: 1_200, height: 630)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            Palette.paper.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            drawPlaceholderSymbol(named: symbol, in: size)
            drawPlaceholderWordmark(label, in: size)
        }
    }

    private func drawPlaceholderSymbol(named symbol: String, in size: CGSize) {
        let halo = UIBezierPath(ovalIn: CGRect(x: 350, y: 60, width: 500, height: 470))
        Palette.sage.withAlphaComponent(0.5).setFill()
        halo.fill()
        let configuration = UIImage.SymbolConfiguration(pointSize: 250, weight: .medium)
        let image = UIImage(systemName: symbol, withConfiguration: configuration)
        let tinted = image?.withTintColor(Palette.moss, renderingMode: .alwaysOriginal)
        tinted?.draw(in: CGRect(x: 475, y: 145, width: 250, height: 250))
    }

    private func drawPlaceholderWordmark(_ label: String, in size: CGSize) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: Palette.moss,
            .paragraphStyle: paragraphStyle
        ]
        let rect = CGRect(x: 0, y: size.height - 88, width: size.width, height: 40)
        label.draw(in: rect, withAttributes: attributes)
    }

    private func workoutLayout(for entry: FernletMessagesWorkoutCatalogEntry) -> MSMessageTemplateLayout {
        let layout = MSMessageTemplateLayout()
        layout.image = workoutPlaceholderImage()
        layout.caption = entry.card.title
        layout.subcaption = workoutSummary(for: entry)
        layout.trailingCaption = entry.card.senderLabel ?? FernletMessagesCopy.cardPlan
        return layout
    }

    private func showReceivedItem(from message: MSMessage) {
        guard let url = message.url else {
            showInvalidReceivedItem()
            return
        }
        do {
            let envelope = try ExchangeMessageEnvelope.decode(messageURL: url)
            switch try envelope.validatedPayload() {
            case .recipe(let packet): try showReceivedRecipe(packet)
            case .workoutPlan(let packet): try showReceivedWorkout(packet, dayKey: envelope.scheduledStartDayKey)
            }
        } catch {
            showInvalidReceivedItem()
        }
    }

    private func showReceivedRecipe(_ packet: RecipeExchangePacket) throws {
        let card = try ExchangeCardMetadata.recipe(from: packet)
        isShowingReceivedItem = true
        receivedRecipe = packet
        receivedWorkout = nil
        let note = packet.recipe.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = note.isEmpty
            ? recipeSummary(for: packet)
            : FernletMessagesCopy.recipeNotePreview(note: String(note.prefix(120)))
        let status = packet.includesNotes
            ? FernletMessagesCopy.receivedRecipeWithNote
            : FernletMessagesCopy.receivedRecipe
        showReceived(title: card.title, status: status, preview: preview)
    }

    private func showReceivedWorkout(_ packet: WorkoutPlanExchangePacket, dayKey: String?) throws {
        let record = try FernletMessagesWorkoutInboxRecord(packet: packet, suggestedStartDayKey: dayKey)
        let card = try ExchangeCardMetadata.workoutPlan(from: packet, scheduledStartDayKey: dayKey)
        let schedule = dayKey.map { FernletMessagesCopy.scheduled(dayKey: $0) }
            ?? FernletMessagesCopy.chooseDateInFernlet
        let status = card.senderLabel.map { FernletMessagesCopy.receivedWorkoutPlan(from: $0) }
            ?? FernletMessagesCopy.receivedWorkoutPlan
        isShowingReceivedItem = true
        receivedRecipe = nil
        receivedWorkout = record
        showReceived(
            title: card.title,
            status: status,
            preview: "\(schedule) · \(FernletMessagesCopy.workoutCount(packet.plan.sessionCount))"
        )
    }

    private func showReceived(title: String, status: String, preview: String) {
        titleLabel.text = title
        statusLabel.text = status
        statusLabel.isHidden = false
        previewLabel.text = preview
        previewLabel.isHidden = preview.isEmpty
        modeControl.isHidden = true
        searchBar.isHidden = true
        itemStack.isHidden = true
        browseButton.isHidden = true
        insertButton.isHidden = true
        reviewButton.isHidden = false
    }

    private func showInvalidReceivedItem() {
        isShowingReceivedItem = true
        receivedRecipe = nil
        receivedWorkout = nil
        showReceived(title: FernletMessagesCopy.invalidTitle,
                     status: FernletMessagesCopy.invalidStatus,
                     preview: FernletMessagesCopy.invalidPreview)
        reviewButton.isHidden = true
    }

    private func openRecipeInFernlet(_ packet: RecipeExchangePacket) {
        guard let directory = FernletMessagesInboxStore.productionDirectory() else {
            statusLabel.text = FernletMessagesCopy.prepareRecipeFailed
            return
        }
        do {
            let record = try FernletMessagesInboxStore(directory: directory).enqueue(packet)
            let target = FernletMessagesInboxTarget(destination: .recipe, inboxID: record.id)
            openFernletReview(target, failure: FernletMessagesCopy.openRecipeFailed)
        } catch {
            statusLabel.text = FernletMessagesCopy.prepareRecipeFailed
        }
    }

    private func openWorkoutInFernlet(_ record: FernletMessagesWorkoutInboxRecord) {
        guard let directory = FernletMessagesWorkoutInboxStore.productionDirectory() else {
            statusLabel.text = FernletMessagesCopy.prepareWorkoutFailed
            return
        }
        do {
            let saved = try FernletMessagesWorkoutInboxStore(directory: directory).enqueue(
                record.packet, suggestedStartDayKey: record.suggestedStartDayKey
            )
            let target = FernletMessagesInboxTarget(destination: .workoutPlan, inboxID: saved.id)
            openFernletReview(target, failure: FernletMessagesCopy.openWorkoutFailed)
        } catch {
            statusLabel.text = FernletMessagesCopy.prepareWorkoutFailed
        }
    }

    private func openFernletReview(_ target: FernletMessagesInboxTarget, failure: String) {
        guard let url = FernletMessagesInboxLink.url(for: target) else {
            statusLabel.text = failure
            return
        }
        extensionContext?.open(url) { [weak self] didOpen in
            self?.statusLabel.text = didOpen
                ? FernletMessagesCopy.openingFernlet
                : FernletMessagesCopy.openFernletToReview
        }
    }
}
