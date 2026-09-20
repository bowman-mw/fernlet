// PresenceAdvertisementTests.swift
// FernletTests
//
// P9 item 2 pass 2 (plan §17.1): the presence radio's WIRE vocabulary, settled as pure values —
// the Bonjour TXT record it publishes and reads back, and the one frame a dialer writes so the
// responder can resolve an inbound QUIC connection to a browsed peer. No radio, no clock, no
// manager: every input here is a literal.

@testable import ProximityKit
import Foundation
import Testing

@Suite(.serialized)
struct PresenceAdvertisementTests {

    /// A base64 tag of the same shape `IdentityService.presenceTag` produces: 8 bytes, 12 chars.
    private func tag(_ seed: UInt8) -> String {
        Data(repeating: seed, count: 8).base64EncodedString()
    }

    private func tags(_ count: Int) -> [String] {
        (0..<count).map { tag(UInt8(truncatingIfNeeded: $0)) }
    }

    // MARK: - The TXT record

    /// The advertisement is the version token and the tags, and there is no third thing in it.
    ///
    /// The identifier-hygiene claim of the whole radio, pinned at the one place it could be
    /// broken by accident: a display name, a session id or a fingerprint added to the record
    /// would compile, pass every other test, and be visible to every passive scanner in the room.
    @Test func theAdvertisementCarriesTheVersionAndTheTagsAndNothingElse() {
        let fields = PresenceAdvertisement.publishedFields(tags: tags(3))
        #expect(fields[PresenceAdvertisement.versionKey] == PresenceAdvertisement.version)
        #expect(Set(fields.keys) == ["v", "t"], "only the version and one tag chunk for a small roster")
        let recovered = PresenceAdvertisement.tags(from: fields)
        #expect(recovered == Set(tags(3)))
    }

    /// A device with no eligible friends still advertises, and advertises a presence record.
    ///
    /// It must look exactly like a device that has friends but is out of range: an advertisement
    /// that vanished when the roster emptied would say "this person has no Fernlet friends" to
    /// anyone watching the air.
    @Test func anEmptyRosterStillAdvertisesAVersionedRecord() {
        let fields = PresenceAdvertisement.publishedFields(tags: [])
        #expect(fields == ["v": "1"])
        #expect(PresenceAdvertisement.isPresenceAdvertisement(fields))
        #expect(PresenceAdvertisement.tags(from: fields).isEmpty)
    }

    /// The full advertise cap survives the wire, and no single TXT entry breaks DNS-SD's ceiling.
    ///
    /// The bug this exists for: `PresenceManager.maxAdvertisedTags` base64 tags with their
    /// separators run past RFC 6763 §6.1's 255-byte limit for ONE `key=value` string, before the
    /// key is counted. Under MultipeerConnectivity that was the framework's problem and its
    /// behaviour was never established; under `NWTXTRecord` it is this type's, and an over-long
    /// entry is refused or truncated, which reads on the air as presence quietly dying once
    /// someone has twenty friends. So the assertion is on the ENTRY, not the total.
    ///
    /// The cap is READ, never repeated: a literal 24 here would keep passing after the production
    /// cap was raised, which is the one change that can break this.
    @Test func aFullRosterIsChunkedInsideTheDNSServiceDiscoveryEntryCeiling() {
        let all = tags(PresenceManager.maxAdvertisedTags)
        let fields = PresenceAdvertisement.publishedFields(tags: all)
        #expect(fields.count > 2, "the full cap does not fit one entry — it must have spilled to a second")
        for (key, value) in fields {
            #expect(value.utf8.count <= PresenceAdvertisement.maxChunkValueBytes)
            #expect((key.utf8.count + 1 + value.utf8.count) <= 255, "\(key) breaks the DNS-SD entry ceiling")
        }
        #expect(PresenceAdvertisement.tags(from: fields) == Set(all), "every advertised tag survives the round trip")
    }

    /// The advertise cap FITS the chunk capacity, computed from the encoder's own constants.
    ///
    /// The production-side guarantee a `static` assertion would make if Swift had one. Tags past
    /// the last chunk are dropped rather than truncated — deliberately, because a truncated tag
    /// matches nothing — so a cap raised past capacity has no symptom at all on the air: the
    /// friends beyond it simply stop being recognized, silently, for everyone. This reddens the
    /// moment the two constants stop agreeing, which is the moment the cap is raised.
    @Test func theAdvertiseCapFitsTheChunkCapacity() {
        let tagBytes = Data(count: IdentityService.presenceTagByteCount).base64EncodedString().utf8.count
        let separatorBytes = PresenceAdvertisement.tagSeparator.utf8.count
        // One chunk holds a first tag plus as many `,tag` groups as fit — the +separator on both
        // sides of the division is that first, separator-less tag.
        let perChunk = (PresenceAdvertisement.maxChunkValueBytes + separatorBytes) / (tagBytes + separatorBytes)
        let capacity = perChunk * PresenceAdvertisement.maxChunks
        #expect(
            PresenceManager.maxAdvertisedTags <= capacity,
            "the advertise cap (\(PresenceManager.maxAdvertisedTags)) is past what \(PresenceAdvertisement.maxChunks) chunks hold (\(capacity)) — tags beyond it are dropped from the air with no symptom"
        )
        // And the encoder agrees with the arithmetic: a full capacity's worth round-trips whole.
        let full = tags(capacity)
        #expect(PresenceAdvertisement.tags(from: PresenceAdvertisement.publishedFields(tags: full)) == Set(full))
    }

    /// The published record is a function of the tag SET alone, not of the order it arrives in.
    ///
    /// Load-bearing rather than tidy: a republish re-registers the Bonjour service, so an
    /// advertisement that differed run to run for an unchanged roster would tear the listener down
    /// and back up on every roster refresh.
    @Test func theRecordIsAFunctionOfTheTagSetAlone() {
        let ordered = PresenceAdvertisement.publishedFields(tags: tags(20))
        let shuffled = PresenceAdvertisement.publishedFields(tags: tags(20).reversed())
        #expect(ordered == shuffled)
    }

    /// A record of another version is believed for nothing at all.
    @Test func aRecordOfAnotherVersionIsNotBelieved() {
        let foreign = ["v": "2", "t": tag(1)]
        #expect(!PresenceAdvertisement.isPresenceAdvertisement(foreign))
        #expect(PresenceAdvertisement.tags(from: foreign).isEmpty)
        #expect(PresenceAdvertisement.tags(from: ["t": tag(1)]).isEmpty, "a record with no version is no record")
        #expect(PresenceAdvertisement.tags(from: nil).isEmpty)
    }

    /// The inbound direction is untrusted wire data and is bounded as such.
    ///
    /// A peer is free to publish a chunk of thousands of comma-separated tokens; the reader takes
    /// at most ``PresenceAdvertisement/maxInboundTags`` of them, and drops empty tokens rather than
    /// matching on a value every malformed record shares.
    @Test func inboundTagsAreBoundedAndEmptyTokensAreDropped() {
        let crowded = Array(repeating: "x", count: 5_000).joined(separator: ",")
        let read = PresenceAdvertisement.tags(from: ["v": "1", "t": crowded])
        #expect(read.count <= PresenceAdvertisement.maxInboundTags)
        #expect(PresenceAdvertisement.tags(from: ["v": "1", "t": ",,,"]).isEmpty)
        #expect(!PresenceAdvertisement.tags(from: ["v": "1", "t": "a,,b"]).contains(""))
    }

    /// A chunk key past the cap is not read, so a peer cannot smuggle extra tags into keys the
    /// writer would never produce.
    @Test func chunkKeysPastTheCapAreNotRead() {
        let overflowKey = PresenceAdvertisement.tagsKey(chunk: PresenceAdvertisement.maxChunks)
        let read = PresenceAdvertisement.tags(from: ["v": "1", "t": tag(1), overflowKey: tag(9)])
        #expect(read == [tag(1)])
    }

    // MARK: - The dial hello

    /// The hello round-trips, and carries the two frozen keys the TXT record uses.
    @Test func theDialHelloRoundTripsUnderTheAdvertisementsOwnVocabulary() throws {
        let encoded = try PresenceDialHello.encoded(tag: tag(7))
        let decoded = try #require(PresenceDialHello.decoded(encoded))
        #expect(decoded.tag == tag(7))
        #expect(decoded.version == PresenceAdvertisement.version)
        let asObject = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: String]
        )
        #expect(Set(asObject.keys) == ["v", "t"], "the hello's keys are the advertisement's, frozen")
    }

    /// Every malformed case has exactly one answer — refuse — so the reader is total.
    @Test func theDialHelloRefusesEverythingItIsNot() throws {
        #expect(PresenceDialHello.decoded(Data()) == nil)
        #expect(PresenceDialHello.decoded(Data("not json".utf8)) == nil)
        #expect(PresenceDialHello.decoded(Data(#"{"v":"2","t":"abc"}"#.utf8)) == nil, "another version")
        #expect(PresenceDialHello.decoded(Data(#"{"v":"1","t":""}"#.utf8)) == nil, "an empty tag names nobody")
        #expect(PresenceDialHello.decoded(Data(#"{"v":"1"}"#.utf8)) == nil, "no tag at all")
        let oversized = Data(repeating: 0x41, count: PresenceDialHello.maxEncodedBytes + 1)
        #expect(PresenceDialHello.decoded(oversized) == nil)
    }

    /// An over-long tag is refused at the writer rather than written and refused by the peer.
    @Test func anOverlongTagIsRefusedBeforeItIsWritten() {
        let huge = String(repeating: "a", count: PresenceDialHello.maxEncodedBytes)
        #expect(throws: MeshTransportError.self) {
            _ = try PresenceDialHello.encoded(tag: huge)
        }
    }
}
