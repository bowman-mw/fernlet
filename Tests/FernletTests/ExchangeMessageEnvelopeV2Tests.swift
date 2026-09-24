import CryptoKit
import FernletDomainModel
import FernletExchange
import Foundation
import Testing

/// The version-2 Messages envelope (2026-09-24): its wire, its bounds, what it still reads, and how
/// much more it carries.
///
/// **What version 2 is.** Version 1 base64'd the packet into the envelope's JSON and base64'd the
/// envelope again into the `data:` URL, so Apple's 5,000-character `MSMessage.url` held a packet of
/// only about 2.6 KB. Version 2 nests the packet as raw JSON in a small document, deflates it (raw
/// DEFLATE), and base64url-encodes the frame once. These tests hold each of those words to the bytes
/// — several decode the wire with Foundation's own `NSData` inflater or build frames with its
/// deflater, so the production codec is checked against an independent implementation, not itself.
///
/// **What must never change.** A version-1 card already sitting in a conversation must keep
/// opening: the two golden URLs below were minted by the untouched 2026-09-23 build (`3eeb7bb`)
/// before this round changed a line, and the version-1 content-hash pre-images are spelled out as
/// literals so the hash scheme is pinned independently of the code that computes it.
struct ExchangeMessageEnvelopeV2Tests {

    // MARK: - The wire

    /// The frame bound is exactly the largest whose unpadded base64url, after the version-2 prefix,
    /// still fits Apple's documented 5,000 characters — safe, and tight. The prefix length is
    /// measured from a real URL rather than restated, so a change to the prefix moves the arithmetic.
    @Test func theFrameBoundIsTheLargestThatFitsApplesMessageURLLimit() throws {
        let envelope = try ExchangeMessageEnvelope(recipe: Self.goldenRecipePacket())
        let url = try envelope.messageURL().absoluteString
        let body = try #require(url.split(separator: ",", maxSplits: 1).last)
        let prefixLength = url.count - body.count
        let urlLength = { (frameBytes: Int) in prefixLength + (frameBytes * 4 + 2) / 3 }

        #expect(prefixLength == 41, "the version-2 prefix is data:application/vnd.fernlet.exchange.v2,")
        #expect(urlLength(ExchangeLimits.maxMessageFrameBytes) <= ExchangeLimits.maxMessageURLCharacters,
                "a frame at the byte bound must still produce a URL Messages accepts")
        #expect(urlLength(ExchangeLimits.maxMessageFrameBytes + 1) > ExchangeLimits.maxMessageURLCharacters,
                "the bound must be tight, not merely safe — one more byte crosses the URL limit")
    }

    /// "Raw packet JSON, compressed, encoded ONCE (base64url)", checked on the bytes with Foundation's
    /// own inflater: the URL body is unpadded base64url, the frame header is magic + version + the
    /// document's exact length, and the inflated document holds the packet as a JSON OBJECT equal to
    /// the packet file — not a base64 string, and with no card.
    @Test func aCardIsDeflatedRawJSONEncodedOnceAsBase64URL() throws {
        let packet = try Self.goldenRecipePacket()
        let url = try ExchangeMessageEnvelope(recipe: packet).messageURL().absoluteString
        let body = String(try #require(url.split(separator: ",", maxSplits: 1).last))
        let frame = try Self.base64URLDecode(body)
        let document = try Self.inflateIndependently(frame)
        let object = try #require(JSONSerialization.jsonObject(with: document) as? [String: Any])
        let packetObject = try #require(JSONSerialization.jsonObject(with: packet.encodedData()) as? [String: Any])

        #expect(url.hasPrefix("data:application/vnd.fernlet.exchange.v2,"))
        #expect(body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, "unpadded base64url only")
        #expect(Array(frame.prefix(2)) == [0x46, 0x02], "magic F, frame version 2")
        #expect(Int(frame[2]) << 8 | Int(frame[3]) == document.count, "the header declares the exact document length")
        #expect(Set(object.keys) == ["format", "formatVersion", "recipe"], "no card, no packetData, no day key on a recipe")
        #expect(object["format"] as? String == "fernlet.exchange.message")
        #expect(object["formatVersion"] as? Int == 2)
        #expect(NSDictionary(dictionary: try #require(object["recipe"] as? [String: Any])) == NSDictionary(dictionary: packetObject),
                "the packet travels as raw JSON, identical to the .fernletrecipe file")
    }

    /// Version 2 still carries workout plans, day suggestion included, and the card the receiver
    /// derives equals the sender's.
    @Test func aWorkoutPlanRoundTripsThroughVersion2WithItsDaySuggestion() throws {
        let original = try ExchangeMessageEnvelope(workoutPlan: Self.goldenWorkoutPacket(), scheduledStartDayKey: "2026-09-02")
        let url = try original.messageURL()
        let recovered = try ExchangeMessageEnvelope.decode(messageURL: url)
        let document = try Self.inflateIndependently(Self.base64URLDecode(Self.urlBody(url)))
        let object = try #require(JSONSerialization.jsonObject(with: document) as? [String: Any])

        #expect(original.formatVersion == 2)
        #expect(recovered == original)
        #expect(recovered.card.scheduledStartDayKey == "2026-09-02")
        #expect(Set(object.keys) == ["format", "formatVersion", "scheduledStartDayKey", "workoutPlan"])
    }

    /// `decode(_:)` reads either wire's bytes, and a decoded envelope equals the one that was sent.
    @Test func rawBytesOfEitherVersionDecode() throws {
        let current = try ExchangeMessageEnvelope(recipe: Self.goldenRecipePacket())
        var legacy = current
        legacy.formatVersion = ExchangeMessageEnvelope.legacyFormatVersion

        #expect(try ExchangeMessageEnvelope.decode(current.encodedData()) == current)
        #expect(try ExchangeMessageEnvelope.decode(legacy.encodedData()) == legacy)
        #expect(throws: ExchangePacketError.invalidPayload) { try ExchangeMessageEnvelope.decode(Data()) }
    }

    /// Two version-2 cards minted by this round's build for the golden inputs. Pinned for DECODING
    /// only — a deflater may legitimately emit different bytes on another OS release, so the encoder
    /// is not held to these — but every one of them must open forever, which is what stops the
    /// version-2 wire (prefix, frame header, document keys) from drifting without a version 3.
    @Test func versionTwoGoldenCardsKeepOpening() throws {
        let recipe = try ExchangeMessageEnvelope.decode(messageURL: #require(URL(string: Self.goldenV2RecipeURL)))
        let workout = try ExchangeMessageEnvelope.decode(messageURL: #require(URL(string: Self.goldenV2WorkoutURL)))
        let expectedRecipe = try ExchangeMessageEnvelope(recipe: Self.goldenRecipePacket())
        let expectedWorkout = try ExchangeMessageEnvelope(workoutPlan: Self.goldenWorkoutPacket(), scheduledStartDayKey: "2026-09-02")

        #expect(recipe == expectedRecipe)
        #expect(workout == expectedWorkout)
    }

    // MARK: - Version 1 still opens

    /// The two cards the 2026-09-23 build minted for fixed inputs, before this round changed a line.
    /// They must open forever: a card in a conversation outlives every app update.
    @Test func versionOneCardsMintedByThe2026_09_23BuildStillOpen() throws {
        let recipe = try ExchangeMessageEnvelope.decode(messageURL: #require(URL(string: Self.goldenV1RecipeURL)))
        let workout = try ExchangeMessageEnvelope.decode(messageURL: #require(URL(string: Self.goldenV1WorkoutURL)))
        let rebuilt = try Self.goldenRecipePacket()

        #expect(recipe.formatVersion == 1)
        guard case .recipe(let recipePacket) = try recipe.validatedPayload(),
              case .workoutPlan(let workoutPacket) = try workout.validatedPayload() else {
            Issue.record("Expected a recipe and a workout plan.")
            return
        }
        #expect(recipePacket.contentHash == Self.goldenV1RecipeHash)
        #expect(recipePacket == rebuilt, "today's builder still makes the packet that card carries")
        #expect(recipe.card.title == "Training oats" && recipe.card.stepCount == 2)
        #expect(workoutPacket.contentHash == Self.goldenV1WorkoutHash)
        #expect(workout.scheduledStartDayKey == "2026-09-02")
        #expect(try recipe.messageURL().absoluteString == Self.goldenV1RecipeURL,
                "a legacy envelope still re-encodes byte-for-byte as the 2026-09-23 build wrote it")
        #expect(try workout.messageURL().absoluteString == Self.goldenV1WorkoutURL)
    }

    /// The version-1 content-hash scheme, pinned independently of the code that computes it: SHA-256
    /// over the canonical pre-image — the packet minus `contentHash`, with `formatVersion` spelled
    /// `version`, keys sorted, slashes unescaped — written out here as a literal.
    @Test func theVersionOneContentHashSchemeIsFrozen() throws {
        let recipeDigest = SHA256.hash(data: Data(Self.goldenV1RecipePreImage.utf8)).map { String(format: "%02x", $0) }.joined()
        let workoutDigest = SHA256.hash(data: Data(Self.goldenV1WorkoutPreImage.utf8)).map { String(format: "%02x", $0) }.joined()

        #expect(recipeDigest == Self.goldenV1RecipeHash)
        #expect(workoutDigest == Self.goldenV1WorkoutHash)
        #expect(try Self.goldenRecipePacket().contentHash == Self.goldenV1RecipeHash)
        #expect(try Self.goldenWorkoutPacket().contentHash == Self.goldenV1WorkoutHash)
    }

    /// Each prefix accepts only its own encoding, so no URL has two readings.
    @Test func eachPrefixAcceptsOnlyItsOwnEncoding() throws {
        let envelope = try ExchangeMessageEnvelope(recipe: Self.goldenRecipePacket())
        let frame = try envelope.encodedData()
        var legacy = envelope
        legacy.formatVersion = ExchangeMessageEnvelope.legacyFormatVersion
        let legacyJSON = try legacy.encodedData()
        let v2Prefix = "data:application/vnd.fernlet.exchange.v2,"
        let v1Prefix = "data:application/vnd.fernlet.exchange+json;base64,"

        // A version-2 frame in STANDARD base64 (padded, `+` and `/` allowed) is not version 2's spelling.
        let standard = try #require(URL(string: v2Prefix + frame.base64EncodedString() + "="))
        #expect(throws: ExchangePacketError.invalidMessageURL) { try ExchangeMessageEnvelope.decode(messageURL: standard) }
        // Version-1 JSON behind the version-2 prefix, and a version-2 frame behind the version-1 prefix.
        let crossedV2 = try #require(URL(string: v2Prefix + Self.base64URLEncode(legacyJSON)))
        let crossedV1 = try #require(URL(string: v1Prefix + frame.base64EncodedString()))
        #expect(throws: ExchangePacketError.invalidPayload) { try ExchangeMessageEnvelope.decode(messageURL: crossedV2) }
        // Binary behind the JSON prefix fails in the JSON decoder itself, as any non-JSON always has.
        #expect(throws: (any Error).self) { try ExchangeMessageEnvelope.decode(messageURL: crossedV1) }
        let foreign = try #require(URL(string: "data:application/json;base64,e30="))
        #expect(throws: ExchangePacketError.invalidMessageURL) { try ExchangeMessageEnvelope.decode(messageURL: foreign) }
    }

    // MARK: - Bounded decompression

    /// A frame that declares more than the document cap is refused on its header, before a byte is
    /// inflated — the body here is not even valid DEFLATE, and the error is still `tooLarge`.
    @Test func aFrameDeclaringMoreThanTheDocumentCapIsRefusedOnItsHeader() throws {
        var frame = Data([0x46, 0x02])
        let declared = ExchangeLimits.maxMessageDocumentBytes + 1
        frame.append(contentsOf: [UInt8(truncatingIfNeeded: declared >> 8), UInt8(truncatingIfNeeded: declared)])
        frame.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])

        #expect(throws: ExchangePacketError.tooLarge) { try ExchangeMessageEnvelope.decode(frame) }
        #expect(throws: ExchangePacketError.tooLarge) { try ExchangeMessageEnvelope.decode(messageURL: Self.url(forFrame: frame)) }
    }

    /// An inflate bomb — a mebibyte of zeros deflated to about a kilobyte, well inside the frame
    /// bound — is stopped at its declared length even when that length is the cap itself, and at a
    /// small declared length it is stopped there instead.
    @Test func anInflateBombStopsAtItsDeclaredLength() throws {
        let bomb = Data(count: 1_024 * 1_024)
        let atCap = try Self.frame(document: bomb, declaredLength: ExchangeLimits.maxMessageDocumentBytes)
        let small = try Self.frame(document: bomb, declaredLength: 100)

        #expect(atCap.count <= ExchangeLimits.maxMessageFrameBytes, "precondition: the bomb fits a card")
        #expect(throws: ExchangePacketError.tooLarge) { try ExchangeMessageEnvelope.decode(messageURL: Self.url(forFrame: atCap)) }
        #expect(throws: ExchangePacketError.tooLarge) { try ExchangeMessageEnvelope.decode(small) }
    }

    /// A stream that ends before its declared length, a stream cut short, a wrong magic byte and a
    /// future frame version are all refused rather than half-read.
    @Test func shortTruncatedAndForeignFramesAreRefused() throws {
        let document = try Self.document(recipe: Self.goldenRecipePacket())
        let lying = try Self.frame(document: document, declaredLength: document.count + 1)
        let honest = try Self.frame(document: document)
        let truncated = honest.prefix(honest.count - 8)
        var wrongMagic = honest
        wrongMagic[0] = 0x47
        var futureVersion = honest
        futureVersion[1] = 0x03

        #expect(throws: ExchangePacketError.invalidPayload) { try ExchangeMessageEnvelope.decode(lying) }
        #expect(throws: ExchangePacketError.invalidPayload) { try ExchangeMessageEnvelope.decode(Data(truncated)) }
        #expect(throws: ExchangePacketError.invalidPayload) { try ExchangeMessageEnvelope.decode(wrongMagic) }
        #expect(throws: ExchangePacketError.unsupportedFormat) { try ExchangeMessageEnvelope.decode(futureVersion) }
        #expect(try ExchangeMessageEnvelope.decode(honest).formatVersion == 2, "control: the honest frame opens")
    }

    /// The document inside a well-formed frame is validated as strictly as the frame: exactly one
    /// packet, a day key only on a workout plan, the version-2 format, and a nested packet whose own
    /// hash still verifies.
    @Test func aWellFramedButInvalidDocumentIsRefused() throws {
        let recipe = try Self.goldenRecipePacket()
        let workout = try Self.goldenWorkoutPacket()
        var tampered = recipe
        tampered.recipe.name = "Not what was hashed"

        let cases: [(String, [String: Any], ExchangePacketError)] = try [
            ("both packets", ["recipe": Self.jsonObject(recipe), "workoutPlan": Self.jsonObject(workout)], .invalidPayload),
            ("no packet", [:], .invalidPayload),
            ("a recipe with a day key", ["recipe": Self.jsonObject(recipe), "scheduledStartDayKey": "2026-09-02"], .invalidPayload),
            ("a tampered packet", ["recipe": Self.jsonObject(tampered)], .invalidHash),
        ]
        for (label, fields, expected) in cases {
            let frame = try Self.frame(document: Self.documentData(fields))
            #expect(throws: expected, "\(label)") { try ExchangeMessageEnvelope.decode(frame) }
        }
        let wrongVersion = try Self.frame(document: Self.documentData(["recipe": Self.jsonObject(recipe)], formatVersion: 3))
        #expect(throws: ExchangePacketError.unsupportedFormat) { try ExchangeMessageEnvelope.decode(wrongVersion) }
    }

    /// Characters outside unpadded base64url, and an impossible length, are refused at the URL.
    @Test func nonBase64URLBodiesAreRefused() throws {
        let prefix = "data:application/vnd.fernlet.exchange.v2,"
        for body in ["RgI", "RgIA.A", "RgIAAA==", "R/IAAA", "R+IAAA", "RgIAA"] {
            let url = try #require(URL(string: prefix + body))
            #expect(throws: ExchangePacketError.self, "body \(body)") { try ExchangeMessageEnvelope.decode(messageURL: url) }
        }
    }

    // MARK: - Capacity

    /// The task's own example: the twelve-step recipe version 1 refused now fits, with room to spare.
    @Test func theTwelveStepRecipeVersionOneRefusedNowFits() throws {
        let packet = try Self.recipePacket(steps: FernletExchangeTests.longSteps(count: 12))
        var legacy = try ExchangeMessageEnvelope(recipe: packet)
        legacy.formatVersion = ExchangeMessageEnvelope.legacyFormatVersion
        let current = try ExchangeMessageEnvelope(recipe: packet)

        #expect(try packet.encodedData().count > 4_000, "precondition: the ~4.6 KB twelve-step recipe")
        #expect(throws: ExchangePacketError.tooLarge) { try legacy.messageURL() }
        let url = try current.messageURL()
        #expect(url.absoluteString.count <= ExchangeLimits.maxMessageURLCharacters)
        #expect(try ExchangeMessageEnvelope.decode(messageURL: url) == current)
    }

    /// Capacity on REALISTIC text — forty distinct method steps and sixteen ingredients, no
    /// repetition to flatter the compressor — measured as the longest prefix of the recipe each
    /// version can carry. Version 1 ran out within a handful of steps; version 2 carries the whole
    /// recipe, which is more than three times the packet bytes version 1 could.
    @Test func versionTwoCarriesAtLeastThreeTimesVersionOneOnRealisticRecipes() throws {
        let legacyFit = try Self.largestFittingPrefix(legacy: true)
        let currentFit = try Self.largestFittingPrefix(legacy: false)

        #expect(legacyFit.steps >= 1 && legacyFit.steps < 12, "version 1 could not carry a realistic twelve-step recipe")
        #expect(currentFit.steps == Self.lasagnaMethod.count, "version 2 carries the whole forty-step, sixteen-ingredient recipe")
        #expect(currentFit.packetBytes >= 3 * legacyFit.packetBytes,
                "v1 carried \(legacyFit.packetBytes) B (\(legacyFit.steps) steps); v2 \(currentFit.packetBytes) B (\(currentFit.steps) steps)")
    }

    /// A recipe that is a legal FILE, and under the shared packet cap, but whose text will not
    /// compress — every step a run of random base64 — is refused by the FRAME bound with
    /// `tooLarge`: the composer's cue to offer the file instead of handing Messages a URL it would
    /// refuse with an unexplained insert failure. (A packet past the cap is refused earlier, at the
    /// envelope's initializer; `FernletExchangeTests` covers that.)
    @Test func aRecipeThatWillNotCompressIsRefusedByTheFrameBound() throws {
        let noise = (0..<30).map { _ in
            RecipeStep(text: Data((0..<135).map { _ in UInt8.random(in: 0...255) }).base64EncodedString())
        }
        let packet = try Self.recipePacket(steps: noise)

        #expect(try packet.encodedData().count <= ExchangeLimits.maxMessagePacketBytes, "precondition: under the packet cap")
        #expect(throws: ExchangePacketError.tooLarge) { try ExchangeMessageEnvelope(recipe: packet).messageURL() }
    }

    // MARK: - Fixtures: golden inputs (identical to the ones the 2026-09-23 build minted from)

    static let goldenV1RecipeHash = "0b0e94b5fee24c80c4f80f3ec061404e88a8af57ea8a8140e40738167af0cd75"
    static let goldenV1WorkoutHash = "755406cee3be9a4cd7084b7dfa4016033ba489b3b8d0c3f5e3b21fb0daa0faa3"

    static let goldenV1RecipePreImage = #"{"format":"fernlet.exchange.recipe","includesNotes":true,"originContentID":"6D1F2A3B-4C5D-4E6F-8A9B-0C1D2E3F4A5B","packetID":"6D1F2A3B-4C5D-4E6F-8A9B-0C1D2E3F4A5B","recipe":{"format":"fernlet.recipe","ingredients":[{"carbs":54,"fat":6,"name":"Rolled oats","protein":10,"quantity":80,"unit":"g"}],"name":"Training oats","notes":"Serve warm.","servings":2,"steps":[{"id":"11111111-2222-4333-8444-555555555555","text":"Warm the oats."},{"durationSeconds":120,"id":"66666666-7777-4888-9999-AAAAAAAAAAAA","text":"Stir in the milk."}],"version":1},"version":1}"#

    static let goldenV1WorkoutPreImage = #"{"format":"fernlet.exchange.workout-plan","originContentID":"C0FFEE00-1234-4567-89AB-CDEF01234567","packetID":"C0FFEE00-1234-4567-89AB-CDEF01234567","plan":{"coachDisplayName":"Fernlet Coach","days":[{"dayIndex":1,"isRestDay":false,"sessions":[{"exercises":[],"kind":"strength","title":"Strength"}],"title":"Wednesday"}],"edits":[],"format":"fernlet.coach.plan","newExercises":[],"planID":"C0FFEE00-1234-4567-89AB-CDEF01234567","schemaVersion":1,"startPolicy":{"kind":"onAccept"},"title":"Wednesday strength"},"version":1}"#

    static let goldenV1RecipeURL = "data:application/vnd.fernlet.exchange+json;base64,eyJjYXJkIjp7ImluZ3JlZGllbnRDb3VudCI6MSwia2luZCI6InJlY2lwZSIsInNlcnZpbmdzIjoyLCJzdGVwQ291bnQiOjIsInRpdGxlIjoiVHJhaW5pbmcgb2F0cyJ9LCJmb3JtYXQiOiJmZXJubGV0LmV4Y2hhbmdlLm1lc3NhZ2UiLCJmb3JtYXRWZXJzaW9uIjoxLCJraW5kIjoicmVjaXBlIiwicGFja2V0RGF0YSI6ImV5SmpiMjUwWlc1MFNHRnphQ0k2SWpCaU1HVTVOR0kxWm1WbE1qUmpPREJqTkdZNE1HWXpaV013TmpFME1EUmxPRGhoT0dGbU5UZGxZVGhoT0RFME1HVTBNRGN6T0RFMk4yRm1NR05rTnpVaUxDSm1iM0p0WVhRaU9pSm1aWEp1YkdWMExtVjRZMmhoYm1kbExuSmxZMmx3WlNJc0ltWnZjbTFoZEZabGNuTnBiMjRpT2pFc0ltbHVZMngxWkdWelRtOTBaWE1pT25SeWRXVXNJbTl5YVdkcGJrTnZiblJsYm5SSlJDSTZJalpFTVVZeVFUTkNMVFJETlVRdE5FVTJSaTA0UVRsQ0xUQkRNVVF5UlROR05FRTFRaUlzSW5CaFkydGxkRWxFSWpvaU5rUXhSakpCTTBJdE5FTTFSQzAwUlRaR0xUaEJPVUl0TUVNeFJESkZNMFkwUVRWQ0lpd2ljbVZqYVhCbElqcDdJbVp2Y20xaGRDSTZJbVpsY201c1pYUXVjbVZqYVhCbElpd2lhVzVuY21Wa2FXVnVkSE1pT2x0N0ltTmhjbUp6SWpvMU5Dd2labUYwSWpvMkxDSnVZVzFsSWpvaVVtOXNiR1ZrSUc5aGRITWlMQ0p3Y205MFpXbHVJam94TUN3aWNYVmhiblJwZEhraU9qZ3dMQ0oxYm1sMElqb2laeUo5WFN3aWJtRnRaU0k2SWxSeVlXbHVhVzVuSUc5aGRITWlMQ0p1YjNSbGN5STZJbE5sY25abElIZGhjbTB1SWl3aWMyVnlkbWx1WjNNaU9qSXNJbk4wWlhCeklqcGJleUpwWkNJNklqRXhNVEV4TVRFeExUSXlNakl0TkRNek15MDRORFEwTFRVMU5UVTFOVFUxTlRVMU5TSXNJblJsZUhRaU9pSlhZWEp0SUhSb1pTQnZZWFJ6TGlKOUxIc2laSFZ5WVhScGIyNVRaV052Ym1Seklqb3hNakFzSW1sa0lqb2lOalkyTmpZMk5qWXROemMzTnkwME9EZzRMVGs1T1RrdFFVRkJRVUZCUVVGQlFVRkJJaXdpZEdWNGRDSTZJbE4wYVhJZ2FXNGdkR2hsSUcxcGJHc3VJbjFkTENKMlpYSnphVzl1SWpveGZYMD0ifQ=="

    static let goldenV1WorkoutURL = "data:application/vnd.fernlet.exchange+json;base64,eyJjYXJkIjp7ImtpbmQiOiJ3b3Jrb3V0UGxhbiIsInNjaGVkdWxlZFN0YXJ0RGF5S2V5IjoiMjAyNi0wOS0wMiIsInNlbmRlckxhYmVsIjoiRmVybmxldCBDb2FjaCIsInRpdGxlIjoiV2VkbmVzZGF5IHN0cmVuZ3RoIiwid29ya291dENvdW50IjoxfSwiZm9ybWF0IjoiZmVybmxldC5leGNoYW5nZS5tZXNzYWdlIiwiZm9ybWF0VmVyc2lvbiI6MSwia2luZCI6IndvcmtvdXRQbGFuIiwicGFja2V0RGF0YSI6ImV5SmpiMjUwWlc1MFNHRnphQ0k2SWpjMU5UUXdObU5sWlROaVpUbGhOR05rTnpBNE5HSTNaR1poTkRBeE5qQXpNMkpoTkRnNVlqTmlPR1F3WXpObU5XVXpZakl4Wm1Jd1pHRmhNR1poWVRNaUxDSm1iM0p0WVhRaU9pSm1aWEp1YkdWMExtVjRZMmhoYm1kbExuZHZjbXR2ZFhRdGNHeGhiaUlzSW1admNtMWhkRlpsY25OcGIyNGlPakVzSW05eWFXZHBia052Ym5SbGJuUkpSQ0k2SWtNd1JrWkZSVEF3TFRFeU16UXRORFUyTnkwNE9VRkNMVU5FUlVZd01USXpORFUyTnlJc0luQmhZMnRsZEVsRUlqb2lRekJHUmtWRk1EQXRNVEl6TkMwME5UWTNMVGc1UVVJdFEwUkZSakF4TWpNME5UWTNJaXdpY0d4aGJpSTZleUpqYjJGamFFUnBjM0JzWVhsT1lXMWxJam9pUm1WeWJteGxkQ0JEYjJGamFDSXNJbVJoZVhNaU9sdDdJbVJoZVVsdVpHVjRJam94TENKcGMxSmxjM1JFWVhraU9tWmhiSE5sTENKelpYTnphVzl1Y3lJNlczc2laWGhsY21OcGMyVnpJanBiWFN3aWEybHVaQ0k2SW5OMGNtVnVaM1JvSWl3aWRHbDBiR1VpT2lKVGRISmxibWQwYUNKOVhTd2lkR2wwYkdVaU9pSlhaV1J1WlhOa1lYa2lmVjBzSW1Wa2FYUnpJanBiWFN3aVptOXliV0YwSWpvaVptVnlibXhsZEM1amIyRmphQzV3YkdGdUlpd2libVYzUlhobGNtTnBjMlZ6SWpwYlhTd2ljR3hoYmtsRUlqb2lRekJHUmtWRk1EQXRNVEl6TkMwME5UWTNMVGc1UVVJdFEwUkZSakF4TWpNME5UWTNJaXdpYzJOb1pXMWhWbVZ5YzJsdmJpSTZNU3dpYzNSaGNuUlFiMnhwWTNraU9uc2lhMmx1WkNJNkltOXVRV05qWlhCMEluMHNJblJwZEd4bElqb2lWMlZrYm1WelpHRjVJSE4wY21WdVozUm9JbjE5Iiwic2NoZWR1bGVkU3RhcnREYXlLZXkiOiIyMDI2LTA5LTAyIn0="

    /// Minted by this round's build (2026-09-24) for the same inputs; decoded, never re-encoded, by
    /// `versionTwoGoldenCardsKeepOpening`.
    static let goldenV2RecipeURL = "data:application/vnd.fernlet.exchange.v2,RgICwpVSTW_bMAz9KwHPliHbsq34lo8G3WWHZdgOww6KTDtCbTmV5K5D4P8-xsnSAt1l7yJRIN97JHWGZnC9ClBBg852GGJ81UdlW4x79F61CNEt5xs6bwYLVRqBQ21OCNUZ9GAD2vCo_JFI-IHjUhzyBjEVWnItGsmbDDUvEsEFSqmkavIS6ZD0goKXmUyKUjVc12V-F_uXoZvoBz9JBMbqbqzRfx4CeqiCGzGCwZnW2M3V4KctURbbZJeusjUTm3zLxEOxY3K1XDO-SbbpQ7YTq3xN_Celn_C_Kt7m8cH-3bWxrcPakBdy-IMmp9yBbrmghi4VRQRW9UQCX4auw3oxKMokN46aMpc-eQTPo7LBhN9QSYpGay5SLUw_78VfnTKWtP6W2-tIYI_uBRe_lOtjevUUUZKft-kDnq6eTE2ZyQ0sJTCRZRmTQgiWvwNRBHy9iH8nxkU44qwXwxSdoR6dCrSaPdLvqIk5ScnszF3cwEoCE1JKtiSw1Tu8ce-DcQtjZ_redE_x3OjLffHTNP0B"

    static let goldenV2WorkoutURL = "data:application/vnd.fernlet.exchange.v2,RgICy5VSy27CMBD8FeQzQc6DV24UgooqVahI7aHisLE3YJE4KDaCCOXfu4aUtioXbvbs7szs2GeWlVUBlsUsw0rnaHt4ElvQG-wVaAxskHXbnnesjCo1i4MuM2KL8pCjXFmo7AzqF6yJI-DBwONjjwc0dSyrXXmwyxxo5sxEqS1q-wxmS53Dfj_iA4EYpjiGSMghH0XpUGYQcX_AwzCFaDROw3QkuQizPvUFfpZyCcAzgPDm6p7zVtnbO-l_9v0uKyu1UXp6dbSYEceUz-dJwrnnB2HkRf3B0BuNJ0_edJbMucMIIao9iB0-NnFbH8R2pgzd61cokBjmV9-dqStRq4TasPjz7A4LLfF08arMGxoXMYszyA1S-PQwtMm1F09YCUUQ3dZdtlNaErWxFeqNdaxW2dyprb6hZv0DfqDUaEjvgqJUtuX5F-7Ff69NVOMx-avrCo_E4j5QAb_fxLiftCxzJWqXV7tIqSdC4N6y5o7pzm3Npmm-AA"

    /// The recipe the golden version-1 card was minted from — every identifier fixed.
    static func goldenRecipePacket() throws -> RecipeExchangePacket {
        let foodID = try #require(UUID(uuidString: "0B7E3C51-6A2D-4E4B-9A55-1F2C3D4E5F60"))
        let food = FoodItem(
            id: foodID, name: "Rolled oats", servingSize: 40, servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 5, carbs: 27, fat: 3), micronutrients: Micronutrients(),
            category: "test", source: .manual, tags: ["recipe"]
        )
        let recipe = RecipeDefinition(
            id: try #require(UUID(uuidString: "6D1F2A3B-4C5D-4E6F-8A9B-0C1D2E3F4A5B")), name: "Training oats", servings: 2,
            ingredients: [RecipeIngredient(foodItemId: foodID, quantity: 80, unit: RecipeUnit.gram.rawValue)],
            notes: "Serve warm.", source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_779_664_800), updatedAt: Date(timeIntervalSince1970: 1_779_664_800),
            steps: [
                RecipeStep(id: try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555")), text: "Warm the oats."),
                RecipeStep(id: try #require(UUID(uuidString: "66666666-7777-4888-9999-AAAAAAAAAAAA")),
                           text: "Stir in the milk.", durationSeconds: 120)
            ]
        )
        return try RecipeExchangePacket(recipe: recipe, foodItems: [food], includesNotes: true)
    }

    /// The one-day plan the golden version-1 workout card was minted from.
    static func goldenWorkoutPacket() throws -> WorkoutPlanExchangePacket {
        let plan = CoachPlan(
            planID: try #require(UUID(uuidString: "C0FFEE00-1234-4567-89AB-CDEF01234567")),
            title: "Wednesday strength", coachDisplayName: "Fernlet Coach",
            days: [CoachPlanDay(dayIndex: 1, title: "Wednesday", sessions: [CoachSession(title: "Strength")])]
        )
        return try WorkoutPlanExchangePacket(plan: plan)
    }

    // MARK: - Fixtures: a realistic long recipe (three parts, forty distinct steps)

    /// Forty distinct method steps of ordinary length — a ragù, a béchamel, then the assembly — so
    /// capacity is measured on text a compressor cannot flatter by repetition.
    static let lasagnaMethod = [
        "Finely dice the onion, carrot and celery; this mix is the soffritto that carries the whole sauce.",
        "Warm two tablespoons of olive oil in a wide, heavy pot over medium-low heat until it shimmers.",
        "Add the soffritto with a pinch of salt and cook gently for twelve minutes, stirring now and then, until soft and sweet.",
        "Push the vegetables aside, turn the heat up, and brown the beef and pork in two batches so the meat sears rather than steams.",
        "Break the meat up with a wooden spoon as it colours, then let it catch on the bottom for a minute before stirring.",
        "Stir in the tomato paste and cook it for two minutes until it darkens to a rusty brick colour.",
        "Pour in the red wine and scrape up every browned bit from the base of the pot while it bubbles.",
        "Let the wine reduce by about half; the sharp smell of alcohol should fade before you move on.",
        "Add the crushed tomatoes, the bay leaves and a parmesan rind if you saved one.",
        "Rinse the tomato tins with a splash of water and add that too, so none of the pulp is wasted.",
        "Bring the sauce to a bare simmer, partly cover it, and leave it to cook for two hours.",
        "Check the ragù every twenty minutes, stirring from the bottom and adding a little water if it thickens too quickly.",
        "In the last half hour, stir in the whole milk; it softens the acidity and makes the meat tender.",
        "Taste and adjust with salt, black pepper and a small pinch of sugar if the tomatoes are sharp.",
        "Fish out the bay leaves and the rind, then let the ragù cool slightly while you make the béchamel.",
        "Warm the milk in a small saucepan with a slice of onion and a clove until steam rises from the surface.",
        "In a separate pan, melt the butter over medium heat until it foams but does not brown.",
        "Whisk in the flour all at once and cook the roux for two minutes, whisking, so it loses its raw taste.",
        "Strain the warm milk and add it a ladle at a time, whisking hard after each addition to keep it smooth.",
        "Keep whisking as the sauce comes to a gentle boil; it will thicken suddenly once it gets there.",
        "Lower the heat and let it simmer for five minutes, stirring the corners where it tends to catch.",
        "Season with salt, white pepper and a generous grating of nutmeg.",
        "Take the pan off the heat and stir in a handful of grated parmesan until it melts.",
        "Press a sheet of baking paper onto the surface so the béchamel does not form a skin while it waits.",
        "Heat the oven to 190C and set a rack in the middle.",
        "Bring a large pot of salted water to the boil if your lasagna sheets need cooking first.",
        "Blanch the sheets for one minute, a few at a time, then lay them flat on a damp tea towel.",
        "Butter a deep baking dish, roughly 30 by 20 centimetres, right up into the corners.",
        "Spread a thin layer of ragù over the base so the first sheets do not stick.",
        "Cover with a single layer of pasta, trimming the sheets to fit rather than overlapping them.",
        "Spoon over a third of the remaining ragù and spread it evenly to the edges.",
        "Drizzle a quarter of the béchamel across the meat and scatter over some parmesan.",
        "Repeat the pasta, ragù and béchamel layers twice more, pressing each layer down lightly.",
        "Finish with a last layer of pasta covered completely by the remaining béchamel.",
        "Tear the mozzarella over the top and finish with the rest of the parmesan.",
        "Cover the dish loosely with foil, tenting it so the cheese does not stick.",
        "Bake for twenty-five minutes, then remove the foil and bake another twenty until golden and bubbling.",
        "Let the lasagna rest for at least fifteen minutes before cutting; it will hold its layers.",
        "Cut into squares with a sharp knife and lift out the first piece with a flexible spatula.",
        "Leftovers keep, covered, for three days in the fridge and reheat well in a low oven.",
    ]

    /// Sixteen ingredients with real-looking macros.
    static let lasagnaFoods: [(name: String, grams: Double, protein: Int, carbs: Int, fat: Int)] = [
        ("Onion", 150, 2, 14, 0), ("Carrot", 120, 1, 12, 0), ("Celery", 80, 1, 2, 0),
        ("Olive oil", 30, 0, 0, 30), ("Beef mince, 10% fat", 500, 103, 0, 50), ("Pork mince", 250, 43, 0, 52),
        ("Tomato paste", 40, 2, 8, 0), ("Red wine", 150, 0, 4, 0), ("Crushed tomatoes", 800, 13, 56, 2),
        ("Whole milk", 900, 30, 43, 32), ("Unsalted butter", 75, 1, 0, 61), ("Plain flour", 75, 8, 57, 1),
        ("Parmesan", 100, 36, 3, 29), ("Mozzarella", 250, 55, 6, 55), ("Dried lasagna sheets", 300, 39, 225, 5),
        ("Nutmeg", 2, 0, 1, 1),
    ]

    static func lasagnaSteps(count: Int) -> [RecipeStep] {
        lasagnaMethod.prefix(max(0, count)).enumerated().map { index, text in
            RecipeStep(text: text, durationSeconds: index.isMultiple(of: 4) ? (index + 2) * 60 : nil)
        }
    }

    /// A recipe with the given steps and the first `ingredientCount` lasagna ingredients.
    static func recipePacket(steps: [RecipeStep], ingredientCount: Int = 1) throws -> RecipeExchangePacket {
        let foods = lasagnaFoods.prefix(max(1, ingredientCount)).map { food in
            FoodItem(id: UUID(), name: food.name, servingSize: food.grams, servingUnit: RecipeUnit.gram.rawValue,
                     macros: Macros(protein: food.protein, carbs: food.carbs, fat: food.fat),
                     micronutrients: Micronutrients(), category: "test", source: .manual, tags: ["recipe"])
        }
        let recipe = RecipeDefinition(
            id: UUID(), name: "Weekend lasagna", servings: 8,
            ingredients: foods.map { RecipeIngredient(foodItemId: $0.id, quantity: $0.servingSize, unit: RecipeUnit.gram.rawValue) },
            notes: "", source: "manual", createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800), steps: steps
        )
        return try RecipeExchangePacket(recipe: recipe, foodItems: foods, includesNotes: false)
    }

    /// The longest prefix of the lasagna method (all sixteen ingredients) that one wire version can
    /// carry, and that packet's size in bytes.
    static func largestFittingPrefix(legacy: Bool) throws -> (steps: Int, packetBytes: Int) {
        var best = (steps: 0, packetBytes: 0)
        for count in 1...lasagnaMethod.count {
            let packet = try recipePacket(steps: lasagnaSteps(count: count), ingredientCount: lasagnaFoods.count)
            do {
                var envelope = try ExchangeMessageEnvelope(recipe: packet)
                if legacy { envelope.formatVersion = ExchangeMessageEnvelope.legacyFormatVersion }
                _ = try envelope.messageURL()
                best = (count, try packet.encodedData().count)
            } catch ExchangePacketError.tooLarge {
                break
            }
        }
        return best
    }

    // MARK: - Independent codec (Foundation's NSData deflater/inflater, not the production filter)

    static func urlBody(_ url: URL) throws -> String {
        String(try #require(url.absoluteString.split(separator: ",", maxSplits: 1).last))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) throws -> Data {
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return try #require(Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)))
    }

    /// Header off, then Foundation's own raw-DEFLATE inflater.
    static func inflateIndependently(_ frame: Data) throws -> Data {
        let body = Data(frame.dropFirst(4))
        return try (body as NSData).decompressed(using: .zlib) as Data
    }

    /// A frame built by Foundation's deflater, with a chosen declared length.
    static func frame(document: Data, declaredLength: Int? = nil) throws -> Data {
        let length = declaredLength ?? document.count
        var frame = Data([0x46, 0x02, UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
        frame.append(try (document as NSData).compressed(using: .zlib) as Data)
        return frame
    }

    static func url(forFrame frame: Data) throws -> URL {
        try #require(URL(string: "data:application/vnd.fernlet.exchange.v2," + base64URLEncode(frame)))
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    /// A version-2 document holding `fields` beside the format keys.
    static func documentData(_ fields: [String: Any], formatVersion: Int = 2) throws -> Data {
        var object = fields
        object["format"] = "fernlet.exchange.message"
        object["formatVersion"] = formatVersion
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func document(recipe: RecipeExchangePacket) throws -> Data {
        try documentData(["recipe": jsonObject(recipe)])
    }
}
