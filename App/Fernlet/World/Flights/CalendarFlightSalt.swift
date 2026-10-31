import CryptoKit
import Foundation
import WorldMapStore

/// The per-install secret the calendar's event hashes are keyed with (World-Airports-Spec §10.4): a later look
/// knows an event by `HMAC(salt, calendarItemExternalIdentifier)` without keeping its ID, and nobody without this
/// iPhone's salt can test an identifier against a hash.
///
/// Kept in the map's sealed vault (`calendar-salt.bin`, the passport's purpose and the store key, bound to its own
/// context so it never opens as another file), never in `UserDefaults`; minted on first use. The vault's wipe
/// (`WorldMapVault.clearAll()`, every Delete everything) removes it with its keys. A passport restored on another
/// iPhone carries hashes under the old salt: those flights are then matched like any other source, by route and
/// ±3 hours.
enum CalendarFlightSalt {
    /// The salt's length, in bytes.
    static let length = 32
    /// The sealed file.
    static let file = WorldMapVault.File(name: "calendar-salt.bin", purpose: WorldMapVault.File.passport.purpose,
                                         role: .store, context: Data("calendarEventHashSalt".utf8))

    /// The salt in `vault`, minted and saved when there's none (or the file can't be opened, or is the wrong
    /// length: a new salt only means older hashes match by route instead). Throws when the vault can't be read or
    /// written now (the phone is locked), never minting over a salt it couldn't reach.
    static func key(in vault: WorldMapVault) throws -> SymmetricKey {
        if let held = try heldSalt(in: vault), held.count == length {
            return SymmetricKey(data: held)
        }
        var generator = SystemRandomNumberGenerator()
        // Bounded: `length` bytes.
        let bytes = Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        try vault.write(bytes, to: file)
        return SymmetricKey(data: bytes)
    }

    /// The saved salt's bytes, nil when there's none or the file can't be opened as one.
    private static func heldSalt(in vault: WorldMapVault) throws -> Data? {
        do {
            return try vault.read(file)
        } catch WorldMapVault.VaultError.unopenable, WorldMapVault.VaultError.tooLarge {
            return nil
        }
    }
}
