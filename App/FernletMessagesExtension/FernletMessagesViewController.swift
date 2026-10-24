import FernletExchange
import Messages
import UIKit

/// A bounded recipe/workout composer. It reads only the App Group catalog and independently
/// decodes every received envelope instead of trusting the visible message card.
///
/// It persists nothing of its own. The one thing it ever remembered — the recipe last picked, in
/// the extension's own `UserDefaults.standard` — was a surface "Delete everything" could not reach
/// (a separate defaults domain the containing app cannot open) and the target's only required-
/// reason API use; it was removed on 2026-09-23 rather than moved, and the compact strip now pins
/// the card picked in the current composer session from memory instead. Its only writes are the
/// review-inbox records `FernletExchange` coordinates, which the app's wipe clears.
///
/// Drawn in the World design language since World Review Batch 4 (`b4-msg-*`, owner, 2026-10-24):
/// the pixel fern and "Fernlet" over a Fraunces title, framed cards with pixel icons, framed
/// Recipes | Workouts and Share, and Dark Mode (``FernletMessagesLook``). What it reads and writes
/// did not change.
final class FernletMessagesViewController: MSMessagesAppViewController, UITextFieldDelegate {
    /// Which half of the App Group catalog the composer is showing.
    ///
    /// The `Int` raw values are the segment indices of Recipes | Workouts, so the segment order and
    /// this declaration order are one fact, not two.
    private enum CatalogMode: Int {
        case recipes
        case workouts
    }

    /// What the panel is showing, which decides what a presentation change or a search keystroke may
    /// redraw.
    ///
    /// `opening` is the state from creation until `willBecomeActive(with:)` has said whether this
    /// activation is a card someone opened or the composer; `viewDidLoad` draws it only while it is
    /// still the state, so a decision made before the view loaded is never reset. Only `composer`
    /// redraws on a transition or a keystroke, so a transition Messages delivers before activation
    /// cannot put the composer — and its catalog read — in front of a received card.
    private enum PanelState {
        case opening
        case composer
        case received
    }

    private let brandView = FernletMessagesBrandView()
    private let titleLabel = FernletMessagesLayout.label(font: FernletMessagesLook.title, colour: FernletMessagesLook.text)
    private let statusLabel = FernletMessagesLayout.label(font: FernletMessagesLook.body, colour: FernletMessagesLook.dim)
    private let modeControl = FernletMessagesSegmentedControl(
        titles: [FernletMessagesCopy.modeRecipes, FernletMessagesCopy.modeWorkouts]
    )
    private let searchField = FernletMessagesSearchField()
    private let previewLabel = FernletMessagesLayout.label(font: FernletMessagesLook.preview, colour: FernletMessagesLook.link)
    private let noticeCard = FernletMessagesNoticeCard(sprite: .bowl, font: FernletMessagesLook.body,
                                                       colour: FernletMessagesLook.text)
    private let detailCard = FernletMessagesNoticeCard(sprite: nil, font: FernletMessagesLook.body,
                                                       colour: FernletMessagesLook.dim)
    private let infoRow = UIView()
    private let headerStack = UIStackView()
    private let itemStack = UIStackView()
    private let browseButton = FernletMessagesButton(kind: .text)
    private let insertButton = FernletMessagesButton(kind: .primary, sprite: .share)
    private let reviewButton = FernletMessagesButton(kind: .primary)
    private var catalog: FernletMessagesCatalog?
    private var selectedRecipeID: UUID?
    private var selectedWorkoutID: UUID?
    private var receivedRecipe: RecipeExchangePacket?
    private var receivedWorkout: FernletMessagesWorkoutInboxRecord?
    private var panelState = PanelState.opening
    private var hasReadCatalog = false
    private var catalogUnavailableMessage: String?
    private var catalogMode = CatalogMode.recipes

    /// Builds the view and shows the opening state — no catalog read, no composer. Until 2026-09-30
    /// this read and validated the whole App Group catalog and built a card per recipe (up to 100 in
    /// the expanded style a received card opens in) before the first frame, for an activation that was
    /// usually about to show one received card instead; `willBecomeActive(with:)` then read the
    /// catalog a second time.
    ///
    /// The opening state is drawn only while nothing has been decided. Messages loaded the view
    /// before `willBecomeActive(with:)` in every run observed, but no documentation promises that
    /// order, and the activation's drawing never loads the view (it sets only labels and controls
    /// this controller owns). So a card already drawn keeps its title, status and Review button
    /// rather than being reset to a brand-mark-only panel, and a composer already decided is redrawn
    /// over `configureView`'s defaults; its catalog was read by the activation that decided it, so
    /// this still reads nothing.
    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        switch panelState {
        case .opening: showOpening()
        case .composer: renderComposer()
        case .received: break
        }
    }

    /// One decision per activation. A card someone opened is drawn from its own URL and nothing else;
    /// only the composer reads the catalog, fresh on every activation, so it still picks up whatever the
    /// app published since the last one.
    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        guard let message = conversation.selectedMessage else {
            reloadCatalog()
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
        guard panelState == .composer else { return }
        renderComposer()
    }

    /// The search field's Search key puts the keyboard away; the list already follows every keystroke.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func searchChanged() {
        guard presentationStyle == .expanded, panelState == .composer else { return }
        renderComposer()
    }

    private func modeChanged(to index: Int) {
        catalogMode = CatalogMode(rawValue: index) ?? .recipes
        searchField.textField.text = ""
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
            showReviewFailure(FernletMessagesCopy.prepareItemFailed)
        }
    }

    /// The panel: an ink edge along its top, then one scrolling column on the page's parchment —
    /// the header, the status line, Recipes | Workouts, search, the preview, the notice, the cards,
    /// the received card's counts, Browse and Review. Each state shows only its own pieces.
    private func configureView() {
        view.backgroundColor = FernletMessagesLook.page
        configureControls()
        configureHeader()
        let contentStack = UIStackView(arrangedSubviews: [
            headerStack, statusLabel, modeControl, searchField, previewLabel, noticeCard, itemStack, detailCard,
            browseButton, reviewButton
        ])
        contentStack.axis = .vertical
        contentStack.spacing = 12
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        let edge = UIView()
        edge.backgroundColor = FernletMessagesLook.ink
        edge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(edge)
        NSLayoutConstraint.activate(scrollConstraints(for: scrollView, contentStack: contentStack) + [
            edge.topAnchor.constraint(equalTo: view.topAnchor),
            edge.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edge.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            edge.heightAnchor.constraint(equalToConstant: 3)
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: FernletMessagesViewController, _: UITraitCollection) in controller.textSizeChanged()
        }
    }

    private func configureControls() {
        modeControl.onChange = { [weak self] index in self?.modeChanged(to: index) }
        searchField.textField.delegate = self
        searchField.textField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        itemStack.axis = .vertical
        itemStack.spacing = 12
        browseButton.addTarget(self, action: #selector(browseItems), for: .touchUpInside)
        browseButton.setTitle(FernletMessagesCopy.browseLibrary)
        browseButton.accessibilityHint = FernletMessagesCopy.browseHint
        insertButton.addTarget(self, action: #selector(insertSelectedItem), for: .touchUpInside)
        insertButton.setTitle(FernletMessagesCopy.shareItem)
        insertButton.accessibilityHint = FernletMessagesCopy.insertHint
        reviewButton.setTitle(FernletMessagesCopy.reviewInFernlet)
        reviewButton.addTarget(self, action: #selector(openReceivedItemInFernlet), for: .touchUpInside)
        reviewButton.accessibilityHint = FernletMessagesCopy.reviewHint
    }

    /// The brand mark, the ⓘ of a card that can't be opened (hidden otherwise) and the title on the
    /// left; Share on the right.
    private func configureHeader() {
        let infoTile = FernletMessagesIconTile(side: 56, sprite: .info, pixel: 3)
        infoRow.addSubview(infoTile)
        NSLayoutConstraint.activate([
            infoTile.centerXAnchor.constraint(equalTo: infoRow.centerXAnchor),
            infoTile.topAnchor.constraint(equalTo: infoRow.topAnchor, constant: 6),
            infoTile.bottomAnchor.constraint(equalTo: infoRow.bottomAnchor, constant: -4)
        ])
        let titleStack = UIStackView(arrangedSubviews: [brandView, infoRow, titleLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 4
        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(insertButton)
        headerStack.spacing = 12
        insertButton.setContentHuggingPriority(.required, for: .horizontal)
        insertButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        applyHeaderAxis()
    }

    /// Share beside the title, or under it at accessibility text sizes, where beside it would squeeze
    /// the title to a word a line.
    private func applyHeaderAxis() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        headerStack.axis = large ? .vertical : .horizontal
        headerStack.alignment = large ? .leading : .top
    }

    /// The column sits in the view's margins; the scroll view reaches `ring` points past them on each
    /// side, so the picked card's moss ring, drawn just outside the card, is never clipped.
    private func scrollConstraints(for scrollView: UIScrollView, contentStack: UIStackView) -> [NSLayoutConstraint] {
        let ring: CGFloat = 4
        return [
            scrollView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: -ring),
            scrollView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: ring),
            scrollView.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: ring),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -ring),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14),
            // Room for the last card's drop shadow and the picked card's ring.
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * ring)
        ]
    }

    /// Hides every piece a state chooses to show, so each state starts from the brand, the title and
    /// the status line and turns on only its own.
    private func hideStatePieces() {
        let pieces: [UIView] = [
            modeControl, searchField, previewLabel, noticeCard, itemStack, detailCard, browseButton, insertButton,
            reviewButton, infoRow
        ]
        pieces.forEach { $0.isHidden = true }
    }

    /// Centres the title, status and preview (the card that can't be opened), or sets them back.
    private func setCentred(_ centred: Bool) {
        let alignment: NSTextAlignment = centred ? .center : .natural
        [titleLabel, statusLabel, previewLabel].forEach { $0.textAlignment = alignment }
    }

    /// The header and the grid follow the text size: Share under the title and one card a row at
    /// accessibility sizes. A change redraws the grid while the composer is up.
    private func textSizeChanged() {
        applyHeaderAxis()
        guard panelState == .composer else { return }
        renderComposer()
    }

    /// The panel before `willBecomeActive(with:)` has decided what it is: the brand mark on the
    /// panel's own paper, with every composer and received-card control hidden. Never an empty panel,
    /// and never the composer's catalog read.
    private func showOpening() {
        panelState = .opening
        titleLabel.text = nil
        statusLabel.text = nil
        statusLabel.isHidden = true
        previewLabel.text = nil
        hideStatePieces()
    }

    /// The composer's catalog, read the first time the composer draws without an activation having
    /// read it — after a received card, say. Every activation that opens the composer re-reads it.
    private func loadCatalogIfNeeded() {
        guard !hasReadCatalog else { return }
        reloadCatalog()
    }

    private func reloadCatalog() {
        hasReadCatalog = true
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
        loadCatalogIfNeeded()
        panelState = .composer
        receivedRecipe = nil
        receivedWorkout = nil
        configureComposerVisibility()
        guard let catalog else {
            titleLabel.text = composerTitle
            setPreviewText("")
            renderButtons([])
            showCatalogNotice(catalogUnavailableMessage ?? FernletMessagesCopy.emptyCatalog)
            return
        }
        switch catalogMode {
        case .recipes: renderRecipes(in: catalog)
        case .workouts: renderWorkouts(in: catalog)
        }
    }

    private func configureComposerVisibility() {
        hideStatePieces()
        setCentred(false)
        modeControl.isHidden = false
        modeControl.select(catalogMode.rawValue)
        searchField.isHidden = presentationStyle != .expanded
        itemStack.isHidden = false
        browseButton.isHidden = presentationStyle == .expanded
        insertButton.isHidden = false
        statusLabel.isHidden = true
        searchField.setPlaceholder(catalogMode == .recipes
            ? FernletMessagesCopy.searchRecipesPlaceholder
            : FernletMessagesCopy.searchWorkoutsPlaceholder)
        // Two whole sentences, not "Browse your %@": the noun cannot be spliced into a
        // possessive in every language, and a translator cannot reorder around the splice.
        browseButton.setTitle(catalogMode == .recipes ? FernletMessagesCopy.browseRecipes : FernletMessagesCopy.browseWorkouts)
    }

    private func renderRecipes(in catalog: FernletMessagesCatalog) {
        let entries = visibleRecipeEntries(in: catalog)
        titleLabel.text = FernletMessagesCopy.shareRecipeTitle
        setPreviewText(recipePreviewText(for: selectedRecipeEntry()))
        insertButton.isEnabled = selectedRecipeEntry() != nil
        renderButtons(entries.map(recipeButton(for:)))
        explainIfEmpty(catalog.recipes.isEmpty)
    }

    private func renderWorkouts(in catalog: FernletMessagesCatalog) {
        let entries = visibleWorkoutEntries(in: catalog)
        titleLabel.text = FernletMessagesCopy.shareWorkoutTitle
        setPreviewText(workoutPreviewText(for: selectedWorkoutEntry()))
        insertButton.isEnabled = selectedWorkoutEntry() != nil
        renderButtons(entries.map(workoutButton(for:)))
        explainIfEmpty(catalog.workouts.isEmpty)
    }

    /// A catalog that decoded fine but holds nothing of the selected kind used to render a title, a
    /// disabled Share button and no cards — a blank panel with no reason given. It gets the same
    /// sentence as a missing catalog, since the remedy (the app publishes what it has) is the same.
    private func explainIfEmpty(_ isEmpty: Bool) {
        guard isEmpty else { return }
        showCatalogNotice(FernletMessagesCopy.emptyCatalog)
    }

    /// The empty or unreadable catalog's sentence in the framed notice, with the chosen kind's pixel
    /// icon (`b4-msg-empty`). Share and Browse step aside: there is nothing to pick.
    private func showCatalogNotice(_ text: String) {
        noticeCard.show(text, sprite: catalogMode == .recipes ? .bowl : .dumbbell)
        noticeCard.isHidden = false
        insertButton.isHidden = true
        browseButton.isHidden = true
    }

    private var composerTitle: String {
        catalogMode == .recipes
            ? FernletMessagesCopy.shareFernletRecipeTitle
            : FernletMessagesCopy.shareFernletWorkoutTitle
    }

    /// The cards, two to a row — one at accessibility text sizes, so a title never squeezes to a word
    /// a line.
    private func renderButtons(_ cards: [FernletMessagesItemCard]) {
        for view in itemStack.arrangedSubviews.prefix(FernletMessagesCatalogLimits.maxRecipes) {
            itemStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let shown = Array(cards.prefix(FernletMessagesCatalogLimits.maxRecipes))
        let perRow = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 1 : 2
        for index in stride(from: 0, to: shown.count, by: perRow) {
            let second = perRow == 2 ? card(at: index + 1, in: shown) : nil
            itemStack.addArrangedSubview(cardRow(first: shown[index], second: second, columns: perRow))
        }
    }

    private func cardRow(first: UIView, second: UIView?, columns: Int) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.spacing = 12
        row.addArrangedSubview(first)
        if let second {
            row.addArrangedSubview(second)
        } else if columns == 2 {
            let spacer = UIView()
            spacer.isUserInteractionEnabled = false
            row.addArrangedSubview(spacer)
        }
        return row
    }

    private func card(at index: Int, in cards: [FernletMessagesItemCard]) -> FernletMessagesItemCard? {
        guard index >= 0, index < cards.count else { return nil }
        return cards[index]
    }

    private func visibleRecipeEntries(in catalog: FernletMessagesCatalog) -> [FernletMessagesRecipeCatalogEntry] {
        if presentationStyle == .expanded {
            return FernletMessagesRecipePicker.entries(matching: searchField.textField.text ?? "", in: catalog)
        }
        // Pins the card picked in THIS composer session — including one chosen from the expanded
        // list — so the selection is still on screen after collapsing. From memory only: see the
        // type's doc comment for why nothing is written to disk.
        return FernletMessagesRecipePicker.compactEntries(in: catalog, lastSelectedRecipeID: selectedRecipeID)
    }

    private func visibleWorkoutEntries(in catalog: FernletMessagesCatalog) -> [FernletMessagesWorkoutCatalogEntry] {
        if presentationStyle == .expanded {
            return FernletMessagesWorkoutPicker.entries(matching: searchField.textField.text ?? "", in: catalog)
        }
        return FernletMessagesWorkoutPicker.compactEntries(in: catalog)
    }

    private func recipeButton(for entry: FernletMessagesRecipeCatalogEntry) -> FernletMessagesItemCard {
        let isSelected = entry.packet.originContentID == selectedRecipeID
        let summary = recipeSummary(for: entry.packet)
        let subtitle = entry.packet.includesNotes
            ? FernletMessagesCopy.recipeSubtitleWithNote(summary: summary)
            : summary
        let card = FernletMessagesItemCard(title: entry.packet.recipe.name, subtitle: subtitle,
                                           sprite: .bowl, isPicked: isSelected)
        card.addAction(UIAction { [weak self] _ in self?.selectRecipe(entry.packet.originContentID) }, for: .touchUpInside)
        return card
    }

    private func workoutButton(for entry: FernletMessagesWorkoutCatalogEntry) -> FernletMessagesItemCard {
        let isSelected = entry.packet.originContentID == selectedWorkoutID
        let card = FernletMessagesItemCard(title: entry.card.title, subtitle: workoutComposerSummary(for: entry),
                                           sprite: .dumbbell, isPicked: isSelected)
        card.addAction(UIAction { [weak self] _ in self?.selectWorkout(entry.packet.originContentID) }, for: .touchUpInside)
        return card
    }

    private func selectRecipe(_ id: UUID) {
        if selectedRecipeID != id { FernletMessagesHaptic.picked.play() }
        selectedRecipeID = id
        renderComposer()
    }

    private func selectWorkout(_ id: UUID) {
        if selectedWorkoutID != id { FernletMessagesHaptic.picked.play() }
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

    private func recipePreviewText(for entry: FernletMessagesRecipeCatalogEntry?) -> String {
        guard let entry else { return "" }
        let detail = entry.packet.includesNotes
            ? notePreviewOrSummary(for: entry.packet)
            : FernletMessagesCopy.recipePreviewWithoutNote(summary: recipeSummary(for: entry.packet))
        return prependingParts(of: entry.packet, to: detail)
    }

    /// The sender's note (its first 120 characters) when there is one, otherwise the counts summary.
    private func notePreviewOrSummary(for packet: RecipeExchangePacket) -> String {
        let note = packet.recipe.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty
            ? recipeSummary(for: packet)
            : FernletMessagesCopy.recipeNotePreview(note: String(note.prefix(120)))
    }

    /// `text` under a "Parts: …" line for a recipe made in parts, or `text` alone for a one-part
    /// recipe. The names are the sender's own words, shown verbatim; the payload's decode has already
    /// bounded them (at most 12 parts, 40 characters each, one line apiece). The two lines are one
    /// catalogued string, so a translator owns their order and the break between them.
    private func prependingParts(of packet: RecipeExchangePacket, to text: String) -> String {
        guard let components = packet.recipe.components, !components.isEmpty else { return text }
        return FernletMessagesCopy.recipePartsPreview(parts: components.map(\.name).joined(separator: " · "),
                                                      detail: text)
    }

    private func workoutPreviewText(for entry: FernletMessagesWorkoutCatalogEntry?) -> String {
        guard let entry else { return "" }
        return workoutComposerSummary(for: entry)
    }

    private func setPreviewText(_ text: String) {
        previewLabel.text = text
        previewLabel.isHidden = text.isEmpty
    }

    /// The card's counts line ("4 servings · 9 ingredients · 6 steps"), from the shared builder so
    /// the composer's cards and the card itself can never disagree.
    private func recipeSummary(for packet: RecipeExchangePacket) -> String {
        FernletMessagesCard.recipeSummary(servings: packet.recipe.servings,
                                          ingredients: packet.recipe.ingredients.count,
                                          steps: packet.recipe.steps?.count ?? 0)
    }

    /// The date and the session count: the line for a workout that carries no notes. Never the notes
    /// themselves.
    private func workoutSummary(for entry: FernletMessagesWorkoutCatalogEntry) -> String {
        "\(entry.dayKey) · \(FernletMessagesCopy.workoutCount(entry.packet.plan.sessionCount))"
    }

    /// The composer's row and preview line, and the sent card's subcaption: ``workoutSummary(for:)``,
    /// plus "Notes included" when the workout's own notes travel inside the card — in the composer
    /// since tracker §2.6 (2026-10-18), so the sender knows before sending, and on the card face since
    /// World Review Batch 4 (`b4-msg-bubbles`, owner, 2026-10-24), as the recipe card already says. The
    /// note text is never shown, here or on the card.
    private func workoutComposerSummary(for entry: FernletMessagesWorkoutCatalogEntry) -> String {
        let summary = workoutSummary(for: entry)
        guard entry.packet.includesNotes else { return summary }
        return FernletMessagesCopy.workoutSubtitleWithNotes(summary: summary)
    }

    private func insertSelectedRecipe() {
        guard let conversation = activeConversation, let entry = selectedRecipeEntry() else {
            showComposerFailure(FernletMessagesCopy.chooseRecipe)
            return
        }
        do {
            // The one card builder, shared with the app's "Send in Messages" (2026-09-30).
            insert(message: try FernletMessagesCard.recipeMessage(for: entry.packet),
                   into: conversation, success: FernletMessagesCopy.recipeInserted)
        } catch ExchangePacketError.tooLarge {
            showComposerFailure(FernletMessagesCopy.recipeTooLarge)
        } catch {
            // Only a size refusal means "use a file instead"; anything else is a failure to say so.
            showComposerFailure(FernletMessagesCopy.insertFailed)
        }
    }

    private func insertSelectedWorkout() {
        guard let conversation = activeConversation, let entry = selectedWorkoutEntry() else {
            showComposerFailure(FernletMessagesCopy.chooseWorkout)
            return
        }
        do {
            let envelope = try ExchangeMessageEnvelope(workoutPlan: entry.packet, scheduledStartDayKey: entry.dayKey)
            insert(message: try FernletMessagesCard.message(for: envelope, layout: workoutLayout(for: entry)),
                   into: conversation, success: FernletMessagesCopy.workoutInserted)
        } catch ExchangePacketError.tooLarge {
            showComposerFailure(FernletMessagesCopy.workoutTooLarge)
        } catch {
            showComposerFailure(FernletMessagesCopy.insertFailed)
        }
    }

    /// Messages documents no queue for this completion, and the label it updates is UIKit state, so
    /// the update hops to the main queue explicitly rather than trusting whichever thread calls back.
    /// The block is `@Sendable` on purpose: the header does not annotate it, so without the mark it
    /// would silently inherit this controller's main-actor isolation — the shape that traps on
    /// device when a framework calls back off-main.
    private func insert(message: MSMessage, into conversation: MSConversation, success: String) {
        conversation.insert(message) { @Sendable [weak self] error in
            let succeeded = error == nil
            DispatchQueue.main.async {
                guard let self else { return }
                if succeeded {
                    self.showComposerStatus(success)
                    FernletMessagesHaptic.inserted.play()
                } else {
                    self.showComposerFailure(FernletMessagesCopy.insertFailed)
                }
            }
        }
    }

    private func showComposerStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }

    /// A share that didn't happen: the status line says why, and the error haptic is its feel (B23).
    private func showComposerFailure(_ text: String) {
        showComposerStatus(text)
        FernletMessagesHaptic.failed.play()
    }

    /// A received card that could not be handed to Fernlet: the status line says so, with the error
    /// haptic. The tap that asked was the person's own, so the failure answers it.
    private func showReviewFailure(_ text: String) {
        statusLabel.text = text
        FernletMessagesHaptic.failed.play()
    }

    /// The workout card's artwork, the pixel dumbbell in the shared builder's scene, like the recipe
    /// card's bowl.
    private func workoutPlaceholderImage() -> UIImage {
        FernletMessagesCard.placeholderImage(sprite: .dumbbell, tag: FernletMessagesCopy.workoutTag)
    }

    private func workoutLayout(for entry: FernletMessagesWorkoutCatalogEntry) -> MSMessageTemplateLayout {
        let layout = MSMessageTemplateLayout()
        layout.image = workoutPlaceholderImage()
        layout.caption = entry.card.title
        layout.subcaption = workoutComposerSummary(for: entry)
        layout.trailingCaption = entry.card.senderLabel ?? FernletMessagesCopy.cardPlan
        layout.trailingSubcaption = FernletMessagesCardCopy.cardOpensInFernlet
        return layout
    }

    /// A thin switch: which screen the card gets is `FernletMessagesReceivedItem.resolve`'s decision,
    /// which `MessagesReceivedItemTests` pins, and every outcome draws a title and a status line.
    private func showReceivedItem(from message: MSMessage) {
        switch FernletMessagesReceivedItem.resolve(messageURL: message.url) {
        case .recipe(let packet, let card): showReceivedRecipe(packet, card: card)
        case .workoutPlan(let record, let card): showReceivedWorkout(record, card: card)
        case .invalid: showInvalidReceivedItem()
        }
    }

    /// A recipe someone sent (`b4-msg-received`): the sender's note in the preview line when one
    /// travels, and the counts — under a "Parts: …" line for a recipe made in parts — in the framed
    /// card above Review in Fernlet.
    private func showReceivedRecipe(_ packet: RecipeExchangePacket, card: ExchangeCardMetadata) {
        receivedRecipe = packet
        receivedWorkout = nil
        let status = packet.includesNotes
            ? FernletMessagesCopy.receivedRecipeWithNote
            : FernletMessagesCopy.receivedRecipe
        showReceived(title: card.title, status: status, preview: receivedNotePreview(for: packet),
                     details: prependingParts(of: packet, to: recipeSummary(for: packet)))
    }

    /// The received recipe's note (its first 120 characters), or nothing when no note travels.
    private func receivedNotePreview(for packet: RecipeExchangePacket) -> String {
        let note = packet.recipe.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard packet.includesNotes, !note.isEmpty else { return "" }
        return FernletMessagesCopy.recipeNotePreview(note: String(note.prefix(120)))
    }

    /// A workout plan someone sent: the sender in the status line, the proposed day and the count in
    /// the framed card.
    private func showReceivedWorkout(_ record: FernletMessagesWorkoutInboxRecord, card: ExchangeCardMetadata) {
        let schedule = record.suggestedStartDayKey.map { FernletMessagesCopy.scheduled(dayKey: $0) }
            ?? FernletMessagesCopy.chooseDateInFernlet
        let status = card.senderLabel.map { FernletMessagesCopy.receivedWorkoutPlan(from: $0) }
            ?? FernletMessagesCopy.receivedWorkoutPlan
        receivedRecipe = nil
        receivedWorkout = record
        showReceived(
            title: card.title,
            status: status,
            preview: "",
            details: "\(schedule) · \(FernletMessagesCopy.workoutCount(record.packet.plan.sessionCount))"
        )
    }

    private func showReceived(title: String, status: String, preview: String, details: String) {
        panelState = .received
        hideStatePieces()
        setCentred(false)
        titleLabel.text = title
        statusLabel.text = status
        statusLabel.isHidden = false
        setPreviewText(preview)
        detailCard.show(details)
        detailCard.isHidden = details.isEmpty
        reviewButton.isHidden = false
    }

    /// A card that can't be opened (`b4-msg-invalid`): the pixel ⓘ over the three centred lines, and
    /// nothing to tap.
    private func showInvalidReceivedItem() {
        receivedRecipe = nil
        receivedWorkout = nil
        showReceived(title: FernletMessagesCopy.invalidTitle,
                     status: FernletMessagesCopy.invalidStatus,
                     preview: FernletMessagesCopy.invalidPreview,
                     details: "")
        reviewButton.isHidden = true
        infoRow.isHidden = false
        setCentred(true)
    }

    private func openRecipeInFernlet(_ packet: RecipeExchangePacket) {
        guard let directory = FernletMessagesInboxStore.productionDirectory() else {
            showReviewFailure(FernletMessagesCopy.prepareRecipeFailed)
            return
        }
        do {
            let record = try FernletMessagesInboxStore(directory: directory).enqueue(packet)
            let target = FernletMessagesInboxTarget(destination: .recipe, inboxID: record.id)
            openFernletReview(target, failure: FernletMessagesCopy.openRecipeFailed)
        } catch {
            showReviewFailure(FernletMessagesCopy.prepareRecipeFailed)
        }
    }

    private func openWorkoutInFernlet(_ record: FernletMessagesWorkoutInboxRecord) {
        guard let directory = FernletMessagesWorkoutInboxStore.productionDirectory() else {
            showReviewFailure(FernletMessagesCopy.prepareWorkoutFailed)
            return
        }
        do {
            let saved = try FernletMessagesWorkoutInboxStore(directory: directory).enqueue(
                record.packet, suggestedStartDayKey: record.suggestedStartDayKey
            )
            let target = FernletMessagesInboxTarget(destination: .workoutPlan, inboxID: saved.id)
            openFernletReview(target, failure: FernletMessagesCopy.openWorkoutFailed)
        } catch {
            showReviewFailure(FernletMessagesCopy.prepareWorkoutFailed)
        }
    }

    private func openFernletReview(_ target: FernletMessagesInboxTarget, failure: String) {
        guard let url = FernletMessagesInboxLink.url(for: target) else {
            showReviewFailure(failure)
            return
        }
        // `open(_:completionHandler:)`'s block is `@Sendable` and runs on no documented queue, so the
        // label is written on main — see `insert(message:into:success:)`.
        extensionContext?.open(url) { [weak self] didOpen in
            DispatchQueue.main.async {
                self?.statusLabel.text = didOpen
                    ? FernletMessagesCopy.openingFernlet
                    : FernletMessagesCopy.openFernletToReview
            }
        }
    }
}
