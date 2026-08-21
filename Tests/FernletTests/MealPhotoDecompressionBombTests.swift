import Foundation
import UIKit
import ImageIO
import Testing
import PrivateMediaStore

/// Round 2026-08-20 §1.3: decompression-bomb gate on `MealPhotoStore`'s SAVE paths.
///
/// The save funnel (`normalizedJPEG`) used to bound each DIMENSION at 20,000 px with no AREA
/// clause, so a declared 20,000 × 20,000 source (400 MP, ~1.6 GB decoded) passed the gate while
/// costing a few hundred KB on the wire as a solid-colour PNG — and PNG has no reduced-size
/// decode, so ImageIO's thumbnail path materialises the full bitmap. Reachable with
/// attacker-declared dimensions via a shared recipe link: `FernletStore.fetchRecipeWebImageIfNeeded`
/// and the share-extension import both feed page-declared og:image bytes into `save(_:forID:)`.
///
/// The gate is deliberately NOT `PrivateMediaStore.isWithinSafePixelBounds` (6,000 px / 24 MP):
/// this store also takes the user's OWN camera/library picks, and a default current-iPhone photo
/// is 5712 × 4284 ≈ 24.5 MP — already over that peer cap — while 48 MP picks are
/// documented-supported ("bounded rather than rejected", the type doc).
/// ``acceptsDefaultCameraSizedPhotoThePeerGateWouldReject()`` pins that difference.
@MainActor
struct MealPhotoDecompressionBombTests {
    private func makeStore() -> (store: MealPhotoStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MealPhotoDecompressionBombTests-\(UUID().uuidString)", isDirectory: true)
        let store = MealPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider())
        return (store, dir)
    }

    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // output pixels == size, so dimensions are deterministic
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.7)!
    }

    // MARK: - Bomb fixture: a REAL, fully decodable huge PNG, built without a bitmap

    /// A header-patched fixture would be vacuous — its truncated pixel data fails ImageIO's decode
    /// even without the gate, so save would return nil either way. This builds a *genuinely
    /// decodable* solid-black grayscale PNG at the declared size instead: the raw scanline stream
    /// of such an image (one 0x00 filter byte + `width` 0x00 pixels per row) is all zeros, which
    /// deflate collapses ~1000×, so the 400 MP bomb is a few hundred KB on disk and no bitmap is
    /// ever materialised here. ``fixtureBuilderEmitsARealDecodablePNG()`` proves the builder.
    private func solidBlackPNG(width: Int, height: Int) throws -> Data {
        let rawCount = height * (width + 1)
        let deflated = try (Data(count: rawCount) as NSData).compressed(using: .zlib) as Data
        // libcompression emits RAW deflate (RFC 1951); a PNG IDAT needs the zlib wrapper
        // (RFC 1950): CMF/FLG header + adler32 trailer. adler32 of an all-zero stream is
        // closed-form: a stays 1, b accumulates a once per byte → ((count % 65521) << 16) | 1.
        var idat = Data([0x78, 0x9C])
        idat.append(deflated)
        idat.append(uint32BE(UInt32(rawCount % 65521) << 16 | 1))
        var ihdr = Data()
        ihdr.append(uint32BE(UInt32(width)))
        ihdr.append(uint32BE(UInt32(height)))
        ihdr.append(contentsOf: [8, 0, 0, 0, 0])  // 8-bit, grayscale, deflate, filter 0, no interlace
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", idat))
        png.append(chunk("IEND", Data()))
        return png
    }

    private func chunk(_ type: String, _ payload: Data) -> Data {
        let body = Data(type.utf8) + payload
        var out = uint32BE(UInt32(payload.count))
        out.append(body)
        out.append(uint32BE(crc32(body)))
        return out
    }

    private func uint32BE(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { n in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = Self.crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: - Tests

    /// The builder emits a valid PNG end to end (chunk CRCs, zlib framing, adler trailer): a small
    /// one decodes to exactly the declared size, and the STORE accepts that same species when it is
    /// small — so the bomb rejections below are the gate's doing, not fixture brokenness.
    @Test func fixtureBuilderEmitsARealDecodablePNG() throws {
        let small = try solidBlackPNG(width: 40, height: 30)
        let image = try #require(UIImage(data: small), "the PNG builder emitted an undecodable file")
        #expect(image.size == CGSize(width: 40, height: 30))

        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.save(try solidBlackPNG(width: 400, height: 300)) != nil,
                "a normally-sized PNG of the bomb's exact species must still save")
    }

    /// A fully decodable image declaring 20,000 × 20,000 — inside the per-dimension cap, 400 MP of
    /// area, ~1.6 GB decoded, a few hundred KB on the wire — is REJECTED by both save entry points
    /// with NOTHING written. Under the pre-fix dimension-only guard this exact fixture passed the
    /// gate and saved, so this test is red there.
    @Test func declaredHugeSolidPNGIsRejectedOnBothSavePaths() throws {
        let bomb = try solidBlackPNG(width: 20_000, height: 20_000)
        // The byte cap alone cannot stop it: the bomb is far below `maxIncomingPhotoBytes` (20 MB).
        #expect(bomb.count < 20 * 1024 * 1024, "fixture no longer small on the wire: \(bomb.count) bytes")
        // And ImageIO really reads the declared 400 MP from its header.
        let source = try #require(CGImageSourceCreateWithData(bomb as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 20_000)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 20_000)

        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Anonymous-id path (meal/progress photos).
        #expect(store.save(bomb) == nil, "a 400 MP decompression bomb was accepted on save")
        // Keyed path (recipe photos — the shared-link web-image sink).
        let recipeID = UUID()
        #expect(store.save(bomb, forID: recipeID) == false,
                "a 400 MP decompression bomb was accepted on the recipe-photo save")
        #expect(!store.hasSealedData(forID: recipeID))
        // Fail-closed means NOTHING written, on either path.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(contents.isEmpty, "a rejected bomb still reached disk: \(contents)")
    }

    /// The reason the gate is an own-sized area cap and not the peer predicate: a DEFAULT
    /// current-iPhone photo (5712 × 4284 ≈ 24.5 MP) fails `isWithinSafePixelBounds` (24 MP), yet
    /// this store must keep its documented promise that the user's own photo is
    /// bounded-then-downscaled, never rejected.
    @Test func acceptsDefaultCameraSizedPhotoThePeerGateWouldReject() throws {
        let photo = jpeg(width: 5712, height: 4284)
        #expect(!PrivateMediaStore.isWithinSafePixelBounds(photo),
                "expected the peer gate to reject a 24.5 MP photo — if this changed, revisit the gate split")

        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try #require(store.save(photo), "a default-sized iPhone camera photo must save")
        let image = try #require(store.imageData(for: id).flatMap(UIImage.init(data:)))
        #expect(max(image.size.width, image.size.height) <= 1600, "photo was not downscaled: \(image.size)")
    }

    /// Everyday-sized images keep saving through both entry points after the gate.
    @Test func normalPhotoStillSavesOnBothPaths() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = jpeg(width: 300, height: 300)

        let id = try #require(store.save(photo))
        #expect(store.imageData(for: id).flatMap(UIImage.init(data:)) != nil)

        let recipeID = UUID()
        #expect(store.save(photo, forID: recipeID))
        #expect(store.imageData(for: recipeID).flatMap(UIImage.init(data:)) != nil)
    }
}
