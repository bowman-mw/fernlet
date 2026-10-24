import FernletUI
import SwiftUI

/// The framed search field at the top of a Settings page (`b2-settings-root`, `b2-settings-memory`,
/// approved 2026-10-23): the pixel magnifier, the field, and a Clear button once there is a query, on
/// raised paper in a 2-pt ink frame (`.fld`).
///
/// It replaces the system search drawer on Settings' first page under the framed look: the drawer
/// lives in a navigation bar, and the panel's wooden plate hides that bar, which left an empty
/// 60-pt band between the plate and the field. The field is a plain `TextField` that VoiceOver hears
/// as a search field; Clear empties it and keeps the keyboard up, as the system field does.
struct SettingsSearchField: View {
    /// The field's name and its prompt (one string, so the prompt adds nothing to translate).
    let title: LocalizedStringKey
    @Binding var text: String
    /// The field's accessibility identifier (UI tests find Settings' field by it).
    var identifier: String = "settings.search"
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        HStack(spacing: 10) {
            FernletIcon(.search, scale: 2)
            TextField(title, text: $text, prompt: .fieldPrompt(title))
                .font(look == nil ? .fernlet(.body) : FernletFramedFont.field)
                .foregroundStyle(look?.text ?? Color.bark)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityAddTraits(.isSearchField)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: { FernletIcon(.close, scale: 2) }
                    .buttonStyle(.plain)
                    .fernletIconButton("Clear search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 4)
        .frame(minHeight: 50)
        .background(look?.raised ?? Color.cream, in: shape)
        .overlay { if let look { shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth) } }
    }
}

/// The chrome of Settings' first page under the framed look. In the World panel the wooden plate
/// names the page, so the page's own navigation bar hides (its title stays for VoiceOver and for the
/// system Back of a page that keeps its bar). In the Settings sheet the sheet header gives the title
/// inside the sheet and Done top right (`b1-frame-sheet`).
struct SettingsRootChrome: ViewModifier {
    let inPanel: Bool
    let isDeleting: Bool
    let onDone: () -> Void

    func body(content: Content) -> some View {
        if inPanel {
            content
                .navigationTitle(Text("Settings"))
                .toolbar(.hidden, for: .navigationBar)
        } else {
            content
                .fernletSheetToolbar(title: "Settings", onDone: onDone, doneDisabled: isDeleting)
        }
    }
}

extension View {
    /// One of Settings' content cards on the framed look's paper (``FernletCard``: a 2-pt ink frame
    /// and a solid shadow), stretched to the page's width with its content leading. Replaces the
    /// pages' hand-made cream cards, so every card on a Settings page is the one approved card.
    func settingsCard() -> some View {
        FernletCard {
            self.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
