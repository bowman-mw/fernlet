import FernletExchange
import Messages
import UIKit

/// A bounded recipe/workout composer. It reads only the privacy-filtered App Group catalog and
/// independently decodes every received envelope instead of trusting the visible message card.
final class FernletMessagesViewController: MSMessagesAppViewController, UISearchBarDelegate {
    private enum CatalogMode: Int {
        case recipes
        case workouts
    }

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["Recipes", "Workouts"])
    private let searchBar = UISearchBar()
    private let previewLabel = UILabel()
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
            statusLabel.text = "Fernlet couldn't prepare this item for review."
        }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        configureLabels()
        configureButtons()
        let contentStack = UIStackView(arrangedSubviews: [
            titleLabel, statusLabel, modeControl, searchBar, previewLabel, itemStack,
            browseButton, insertButton, reviewButton
        ])
        contentStack.axis = .vertical
        contentStack.spacing = 12
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate(scrollConstraints(for: scrollView, contentStack: contentStack))
    }

    private func configureLabels() {
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.numberOfLines = 0
        modeControl.selectedSegmentIndex = CatalogMode.recipes.rawValue
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        itemStack.axis = .vertical
        itemStack.spacing = 8
        searchBar.delegate = self
    }

    private func configureButtons() {
        browseButton.addTarget(self, action: #selector(browseItems), for: .touchUpInside)
        browseButton.accessibilityHint = "Shows the full bounded Fernlet Messages catalog."
        insertButton.addTarget(self, action: #selector(insertSelectedItem), for: .touchUpInside)
        insertButton.accessibilityHint = "Adds the selected Fernlet item to this Messages conversation."
        reviewButton.setTitle("Review in Fernlet", for: .normal)
        reviewButton.addTarget(self, action: #selector(openReceivedItemInFernlet), for: .touchUpInside)
        reviewButton.accessibilityHint = "Opens Fernlet to review this item before saving it."
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
            catalogUnavailableMessage = "Fernlet shared storage isn't available."
            return
        }
        do {
            catalog = try FernletMessagesCatalogFileStore(directory: directory).read()
            catalogUnavailableMessage = nil
        } catch {
            catalog = nil
            catalogUnavailableMessage = "Fernlet couldn't read your Messages catalog. Open Fernlet and try again."
        }
    }

    private func renderComposer() {
        isShowingReceivedItem = false
        receivedRecipe = nil
        receivedWorkout = nil
        configureComposerVisibility()
        guard let catalog else {
            titleLabel.text = composerTitle
            statusLabel.text = catalogUnavailableMessage ?? "Open Fernlet to prepare items for Messages."
            previewLabel.text = ""
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
        searchBar.placeholder = catalogMode == .recipes ? "Search recipes" : "Search workout plans"
        browseButton.setTitle("Browse \(catalogMode == .recipes ? "recipes" : "workouts")", for: .normal)
        insertButton.setTitle("Insert \(catalogMode == .recipes ? "recipe" : "workout plan")", for: .normal)
    }

    private func renderRecipes(in catalog: FernletMessagesCatalog) {
        let entries = visibleRecipeEntries(in: catalog)
        titleLabel.text = presentationStyle == .expanded ? "Browse Fernlet recipes" : "Share a Fernlet recipe"
        statusLabel.text = entries.isEmpty ? "Open Fernlet to prepare a recipe." : "Notes are excluded from Messages recipes."
        previewLabel.text = recipePreviewText(for: selectedRecipeEntry())
        insertButton.isEnabled = selectedRecipeEntry() != nil
        renderButtons(entries.map(recipeButton(for:)))
    }

    private func renderWorkouts(in catalog: FernletMessagesCatalog) {
        let entries = visibleWorkoutEntries(in: catalog)
        titleLabel.text = presentationStyle == .expanded ? "Browse Fernlet workouts" : "Share a Fernlet workout"
        statusLabel.text = entries.isEmpty ? "Open Fernlet to prepare a workout." : "Fernlet will recheck your calendar before import."
        previewLabel.text = workoutPreviewText(for: selectedWorkoutEntry())
        insertButton.isEnabled = selectedWorkoutEntry() != nil
        renderButtons(entries.map(workoutButton(for:)))
    }

    private var composerTitle: String {
        catalogMode == .recipes ? "Share a Fernlet recipe" : "Share a Fernlet workout"
    }

    private func renderButtons(_ buttons: [UIButton]) {
        for view in itemStack.arrangedSubviews.prefix(FernletMessagesCatalogLimits.maxRecipes) {
            itemStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for button in buttons.prefix(FernletMessagesCatalogLimits.maxRecipes) {
            itemStack.addArrangedSubview(button)
        }
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
        let button = catalogButton(title: entry.packet.recipe.name, subtitle: recipeSummary(for: entry.packet))
        button.addAction(UIAction { [weak self] _ in self?.selectRecipe(entry.packet.originContentID) }, for: .touchUpInside)
        return button
    }

    private func workoutButton(for entry: FernletMessagesWorkoutCatalogEntry) -> UIButton {
        let button = catalogButton(title: entry.card.title, subtitle: workoutSummary(for: entry))
        button.addAction(UIAction { [weak self] _ in self?.selectWorkout(entry.packet.originContentID) }, for: .touchUpInside)
        return button
    }

    private func catalogButton(title: String, subtitle: String) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = title
        button.accessibilityHint = subtitle
        return button
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
        guard let entry else { return "Choose a recipe to preview its servings, ingredients, and steps." }
        return "\(recipeSummary(for: entry.packet)) · Notes excluded"
    }

    private func workoutPreviewText(for entry: FernletMessagesWorkoutCatalogEntry?) -> String {
        guard let entry else { return "Choose a workout to preview its scheduled date and session count." }
        return workoutSummary(for: entry)
    }

    private func recipeSummary(for packet: RecipeExchangePacket) -> String {
        let servings = packet.recipe.servings
        let ingredients = packet.recipe.ingredients.count
        let steps = packet.recipe.steps?.count ?? 0
        return "\(servings) servings · \(ingredients) ingredients · \(steps) steps"
    }

    private func workoutSummary(for entry: FernletMessagesWorkoutCatalogEntry) -> String {
        let workouts = entry.packet.plan.sessionCount
        let unit = workouts == 1 ? "workout" : "workouts"
        return "\(entry.dayKey) · \(workouts) \(unit)"
    }

    private func insertSelectedRecipe() {
        guard let conversation = activeConversation, let entry = selectedRecipeEntry() else {
            statusLabel.text = "Choose a recipe to insert."
            return
        }
        do {
            let envelope = try ExchangeMessageEnvelope(recipe: entry.packet)
            insert(message: try message(for: envelope, layout: recipeLayout(for: entry.packet)), into: conversation, success: "Recipe inserted.")
        } catch {
            statusLabel.text = "This recipe is too large for a Messages card. Export a Fernlet recipe file instead."
        }
    }

    private func insertSelectedWorkout() {
        guard let conversation = activeConversation, let entry = selectedWorkoutEntry() else {
            statusLabel.text = "Choose a workout plan to insert."
            return
        }
        do {
            let envelope = try ExchangeMessageEnvelope(workoutPlan: entry.packet, scheduledStartDayKey: entry.dayKey)
            insert(message: try message(for: envelope, layout: workoutLayout(for: entry)), into: conversation, success: "Workout plan inserted.")
        } catch {
            statusLabel.text = "This plan is too large for Messages. Use Export workout plan in Shortcuts or Files."
        }
    }

    private func message(for envelope: ExchangeMessageEnvelope, layout: MSMessageTemplateLayout) throws -> MSMessage {
        let message = MSMessage()
        message.url = try envelope.messageURL()
        message.layout = layout
        message.summaryText = "Fernlet: \(envelope.card.title)"
        return message
    }

    private func insert(message: MSMessage, into conversation: MSConversation, success: String) {
        conversation.insert(message) { [weak self] error in
            self?.statusLabel.text = error == nil ? success : "Fernlet couldn't insert this item."
        }
    }

    private func recipeLayout(for packet: RecipeExchangePacket) -> MSMessageTemplateLayout {
        let layout = MSMessageTemplateLayout()
        layout.image = UIImage(systemName: "leaf.circle.fill")
        layout.caption = packet.recipe.name
        layout.subcaption = recipeSummary(for: packet)
        layout.trailingCaption = "Fernlet recipe"
        return layout
    }

    private func workoutLayout(for entry: FernletMessagesWorkoutCatalogEntry) -> MSMessageTemplateLayout {
        let layout = MSMessageTemplateLayout()
        layout.image = UIImage(systemName: "figure.strengthtraining.traditional")
        layout.caption = entry.card.title
        layout.subcaption = workoutSummary(for: entry)
        layout.trailingCaption = entry.card.senderLabel ?? "Fernlet plan"
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
        guard !packet.includesNotes, packet.recipe.notes.isEmpty else { throw ExchangePacketError.invalidPayload }
        let card = try ExchangeCardMetadata.recipe(from: packet)
        isShowingReceivedItem = true
        receivedRecipe = packet
        receivedWorkout = nil
        showReceived(title: card.title, status: "Fernlet recipe", preview: "\(recipeSummary(for: packet)) · Notes excluded")
    }

    private func showReceivedWorkout(_ packet: WorkoutPlanExchangePacket, dayKey: String?) throws {
        let record = try FernletMessagesWorkoutInboxRecord(packet: packet, suggestedStartDayKey: dayKey)
        let card = try ExchangeCardMetadata.workoutPlan(from: packet, scheduledStartDayKey: dayKey)
        let schedule = dayKey.map { "Scheduled \($0)" } ?? "Choose a date in Fernlet"
        let workouts = packet.plan.sessionCount
        let sender = card.senderLabel.map { " · \($0)" } ?? ""
        isShowingReceivedItem = true
        receivedRecipe = nil
        receivedWorkout = record
        showReceived(title: card.title, status: "Fernlet workout plan\(sender)", preview: "\(schedule) · \(workouts) workouts")
    }

    private func showReceived(title: String, status: String, preview: String) {
        titleLabel.text = title
        statusLabel.text = status
        previewLabel.text = preview
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
        showReceived(title: "This Fernlet item can't be opened", status: "The message data is unsupported or invalid.", preview: "No item was saved or imported.")
        reviewButton.isHidden = true
    }

    private func openRecipeInFernlet(_ packet: RecipeExchangePacket) {
        guard let directory = FernletMessagesInboxStore.productionDirectory() else {
            statusLabel.text = "Fernlet couldn't prepare this recipe for review."
            return
        }
        do {
            let record = try FernletMessagesInboxStore(directory: directory).enqueue(packet)
            let target = FernletMessagesInboxTarget(destination: .recipe, inboxID: record.id)
            openFernletReview(target, failure: "Fernlet couldn't open this recipe for review.")
        } catch {
            statusLabel.text = "Fernlet couldn't prepare this recipe for review."
        }
    }

    private func openWorkoutInFernlet(_ record: FernletMessagesWorkoutInboxRecord) {
        guard let directory = FernletMessagesWorkoutInboxStore.productionDirectory() else {
            statusLabel.text = "Fernlet couldn't prepare this workout plan for review."
            return
        }
        do {
            let saved = try FernletMessagesWorkoutInboxStore(directory: directory).enqueue(
                record.packet, suggestedStartDayKey: record.suggestedStartDayKey
            )
            let target = FernletMessagesInboxTarget(destination: .workoutPlan, inboxID: saved.id)
            openFernletReview(target, failure: "Fernlet couldn't open this workout plan for review.")
        } catch {
            statusLabel.text = "Fernlet couldn't prepare this workout plan for review."
        }
    }

    private func openFernletReview(_ target: FernletMessagesInboxTarget, failure: String) {
        guard let url = FernletMessagesInboxLink.url(for: target) else {
            statusLabel.text = failure
            return
        }
        extensionContext?.open(url) { [weak self] didOpen in
            self?.statusLabel.text = didOpen ? "Opening Fernlet for review…" : "Open Fernlet to review this item."
        }
    }
}
