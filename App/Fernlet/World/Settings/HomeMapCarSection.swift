import FernletFoundation
import FernletUI
import SwiftUI

/// Settings → Home map's "Your car" section (owner 2026-11-09, car signals; rows and wording approved, "Looks good"),
/// under Location: the cars Fernlet knows, how Driving Focus and Shortcuts can start a drive.
///
/// - **My car:** one row per car the car book holds (``WorldCarKeeper/visibleCars``), the first with the line that
///   says what it does, each with its own forget (one car: "Forget my car"; several: "Forget "Camry""), after a
///   confirmation. With none, the row says Fernlet learns the car by itself.
/// - **Use "Camry" as my car:** while a Bluetooth device that is neither a car nor headphones is connected
///   (``WorldCarKeeper/offerable``), a row marks it at once.
/// - **Driving Focus** and **Shortcuts:** what to add where; nothing to switch here.
///
/// A decoy shows no cars and offers none (the keeper sees to that), so a car's name never shows in one.
struct HomeMapCarSection: View {
    @Bindable var cars: WorldCarKeeper
    /// The car waiting on the forget confirmation.
    @State private var forgetting: WorldCarBook.Car?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        FernletFramedSection(header: Text(HomeMapCarCopy.header)) {
            carRows
            if let device = cars.offerable {
                Button { mark(device) } label: {
                    FernletRowLabel(title: Text(HomeMapCarCopy.use(device.name)))
                }
                .buttonStyle(FernletRowButtonStyle(showsChevron: true))
                .accessibilityIdentifier("settings.homeMap.car.use")
            }
            FernletRowLabel("Driving Focus",
                            detail: "Add Fernlet's \"Map my drive\" filter to Driving in Settings › Focus, so the map starts when you drive.")
                .accessibilityElement(children: .combine)
            FernletRowLabel("Shortcuts", detail: "\"Start a drive\" and \"End a drive\" can run when your car connects.")
                .accessibilityElement(children: .combine)
        }
        .alert(Text(HomeMapCarCopy.forgetTitle(forgetting?.name ?? "")), isPresented: isForgetting, presenting: forgetting) { car in
            Button("Forget", role: .destructive) { forget(car) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(HomeMapCarCopy.forgetMessage)
        }
    }

    /// The cars, each with its forget, or the line for none yet.
    @ViewBuilder private var carRows: some View {
        let known = cars.visibleCars
        if known.isEmpty {
            FernletRowLabel(title: Text("My car"), detail: Text(HomeMapCarCopy.noneYet), value: Text(HomeMapCarCopy.none))
                .accessibilityElement(children: .combine)
        }
        ForEach(Array(known.enumerated()), id: \.element.id) { index, car in
            carRow(car, explains: index == 0)
            Button { forgetting = car } label: {
                FernletRowLabel(title: Text(known.count == 1 ? HomeMapCarCopy.forgetOnly : HomeMapCarCopy.forget(car.name)),
                                destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))
            .accessibilityIdentifier("settings.homeMap.car.forget")
        }
    }

    /// One car's row: "My car" and its name, the first with what it does; at the accessibility sizes the name takes
    /// the second line.
    private func carRow(_ car: WorldCarBook.Car, explains: Bool) -> some View {
        let name = Text(verbatim: car.name)
        let large = dynamicTypeSize.isAccessibilitySize
        let detail = explains ? Text("Fernlet knows you're driving when your iPhone connects to it.") : nil
        return FernletRowLabel(title: Text("My car"), detail: large ? name : detail, value: large ? nil : name)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.homeMap.car")
    }

    /// The forget confirmation is up while a car waits on it.
    private var isForgetting: Binding<Bool> {
        Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })
    }

    /// Marks the connected device as a car and says so.
    private func mark(_ device: WorldAudioDevice) {
        cars.mark(device)
        FernletAnnouncer.system.announce(.success, resolved: String(localized: HomeMapCarCopy.marked(device.name)))
    }

    /// Forgets `car` and says so.
    private func forget(_ car: WorldCarBook.Car) {
        cars.forget(tag: car.tag)
        forgetting = nil
        FernletAnnouncer.system.announce(.status, resolved: String(localized: HomeMapCarCopy.forgotten(car.name)))
    }
}

/// The "Your car" section's keyed copy (owner 2026-11-09): lines that carry a car's name, and the none-yet line.
nonisolated enum HomeMapCarCopy {
    static let header = LocalizedStringResource("homeMap.car.header", defaultValue: "Your car",
                                                comment: "Settings, Home map: the section about the person's cars")
    static let none = LocalizedStringResource("homeMap.car.none", defaultValue: "None yet",
                                              comment: "Settings, Home map: My car's value before Fernlet knows a car")
    static let noneYet = LocalizedStringResource(
        "homeMap.car.noneYet", defaultValue: "Fernlet learns your car's Bluetooth after a few drives, or asks you.",
        comment: "Settings, Home map: under My car before any car is known; Fernlet learns it from drives or asks on Home")
    static let forgetOnly = LocalizedStringResource("homeMap.car.forgetOnly", defaultValue: "Forget my car",
                                                    comment: "Settings, Home map: destructive row under the one known car")
    static let forgetMessage = LocalizedStringResource(
        "homeMap.car.forgetMessage", defaultValue: "Fernlet may learn it again after a few drives.",
        comment: "Settings, Home map: the forget-car confirmation's message")

    /// "Use "Camry" as my car".
    static func use(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("homeMap.car.use", defaultValue: "Use \"\(name)\" as my car",
                                comment: "Settings, Home map: marks the connected Bluetooth device as a car; the device's name")
    }

    /// "Forget "Camry"" (several cars).
    static func forget(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("homeMap.car.forget", defaultValue: "Forget \"\(name)\"",
                                comment: "Settings, Home map: destructive row under one of several cars; the car's name")
    }

    /// The forget confirmation's title.
    static func forgetTitle(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("homeMap.car.forgetTitle", defaultValue: "Forget \"\(name)\"?",
                                comment: "Settings, Home map: the forget-car confirmation's title; the car's name")
    }

    /// VoiceOver after marking.
    static func marked(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("homeMap.car.marked", defaultValue: "\(name) is your car.",
                                comment: "VoiceOver, Settings, Home map: after marking a Bluetooth device as a car; its name")
    }

    /// VoiceOver after forgetting.
    static func forgotten(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("homeMap.car.forgotten", defaultValue: "Forgot \(name).",
                                comment: "VoiceOver, Settings, Home map: after forgetting a car; its name")
    }
}
