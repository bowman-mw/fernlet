@testable import ProximityKit
@testable import FernletSocial
import FernletDomainModel
import Foundation
import Testing
@testable import Fernlet

/// Road trip photos on the wire (World-RoadTrip-Spec PR 3, owner-approved 2026-11-10): a photo goes in 1 MiB pieces,
/// each carrying the whole photo's length and SHA-256; the pieces are put back together in any order, checked piece
/// against piece and whole against digest, and bounded; a cut-off photo resumes when it is sent again and is dropped
/// when its pieces stop; the `.photo` kind and the catch-up's held list round-trip under the one token; and the
/// exchange gathers photos only from a kept friend through its open gate.
@Suite(.serialized) @MainActor
struct RoadTripPhotoTransferTests {
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)
    private static let chunk = RoadTripPhotoChunkPayload.chunkBytes

    /// `count` bytes that differ from byte to byte (seeded, so two photos differ).
    static func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// A photo to send, taken at the start.
    static func photo(_ id: UUID = UUID(), trip: UUID = UUID()) -> RoadTripOutgoingPhoto {
        RoadTripOutgoingPhoto(tripID: trip, photoID: id, takenAt: start)
    }

    // MARK: Pieces

    /// The piece count and lengths follow the 1 MiB rule, from one byte to the 10 MiB cap; nothing outside it.
    @Test func piecesFollowTheSizeRule() {
        #expect(RoadTripPhotoChunkPayload.chunkCount(forBytes: 0) == 0)
        #expect(RoadTripPhotoChunkPayload.chunkCount(forBytes: 1) == 1)
        #expect(RoadTripPhotoChunkPayload.chunkCount(forBytes: Self.chunk) == 1)
        #expect(RoadTripPhotoChunkPayload.chunkCount(forBytes: Self.chunk + 1) == 2)
        #expect(RoadTripPhotoChunkPayload.chunkCount(forBytes: RoadTripPhotoChunkPayload.maxPhotoBytes) == 10)
        #expect(RoadTripPhotoChunkPayload.chunkCount(forBytes: RoadTripPhotoChunkPayload.maxPhotoBytes + 1) == 0)
        #expect(RoadTripPhotoChunkPayload.pieceLength(index: 1, byteCount: Self.chunk + 5) == 5)
        #expect(RoadTripPhotoChunkPayload.pieceLength(index: 2, byteCount: Self.chunk + 5) == 0)
        #expect(RoadTripPhotoChunker.chunks(of: Data(), for: Self.photo()).isEmpty, "an empty photo has no pieces")
        #expect(RoadTripPhotoChunker.chunks(of: Self.bytes(RoadTripPhotoChunkPayload.maxPhotoBytes + 1), for: Self.photo()).isEmpty,
                "a photo over the cap is never sent")
    }

    /// A piece whose length, place, count, digest or time disagrees with the photo it describes is malformed.
    @Test func aPieceThatDisagreesIsMalformed() throws {
        let pieces = RoadTripPhotoChunker.chunks(of: Self.bytes(Self.chunk + 100), for: Self.photo())
        try #require(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.isWellFormed })
        let good = pieces[1]
        func with(index: Int = good.index, count: Int = good.count, sha: String = good.sha256, takenAt: Int64 = good.takenAt,
                  bytes: Data = good.bytes) -> RoadTripPhotoChunkPayload {
            RoadTripPhotoChunkPayload(tripID: good.tripID, photoID: good.photoID, takenAt: takenAt, byteCount: good.byteCount,
                                      sha256: sha, index: index, count: count, bytes: bytes)
        }
        #expect(!with(bytes: Self.bytes(99)).isWellFormed, "the last piece's length is fixed by the photo's")
        #expect(!with(index: 2).isWellFormed && !with(index: -1).isWellFormed)
        #expect(!with(count: 3).isWellFormed, "the count is fixed by the length")
        #expect(!with(sha: String(repeating: "A", count: 64)).isWellFormed && !with(sha: "abc").isWellFormed, "lowercase hex only")
        #expect(!with(takenAt: -1).isWellFormed)
    }

    // MARK: Putting it back together

    /// A photo split into three pieces comes back whole, whatever order the pieces land in, with its trip, id and time.
    @Test func aPhotoComesBackWholeInAnyOrder() throws {
        let bytes = Self.bytes(Self.chunk * 2 + 12_345)
        let photo = Self.photo()
        let pieces = RoadTripPhotoChunker.chunks(of: bytes, for: photo)
        try #require(pieces.count == 3 && pieces.allSatisfy { $0.sha256 == RoadTripPhotoChunker.digest(bytes) })
        var assembler = RoadTripPhotoAssembler()
        #expect(assembler.accept(pieces[2], from: "rae", now: Self.start) == .gathering)
        #expect(assembler.accept(pieces[0], from: "rae", now: Self.start) == .gathering)
        #expect(assembler.accept(pieces[0], from: "rae", now: Self.start) == .gathering, "a piece twice is harmless")
        let outcome = assembler.accept(pieces[1], from: "rae", now: Self.start)
        let expected = RoadTripReceivedPhoto(tripID: photo.tripID, photoID: photo.photoID, takenAt: Self.start, bytes: bytes)
        #expect(outcome == .complete(expected))
        #expect(assembler.inFlight == 0, "a finished photo is forgotten")
    }

    /// Bytes that don't match the digest, and a piece describing its photo differently, are refused, and the photo
    /// is dropped; pieces from another sender never mix in.
    @Test func aPhotoThatDoesNotCheckOutIsRefused() throws {
        let bytes = Self.bytes(Self.chunk + 10)
        let pieces = RoadTripPhotoChunker.chunks(of: bytes, for: Self.photo())
        var tampered = pieces[1].bytes
        tampered[tampered.startIndex] ^= 0xFF
        let bad = RoadTripPhotoChunkPayload(tripID: pieces[1].tripID, photoID: pieces[1].photoID, takenAt: pieces[1].takenAt,
                                            byteCount: pieces[1].byteCount, sha256: pieces[1].sha256, index: 1,
                                            count: pieces[1].count, bytes: tampered)
        var assembler = RoadTripPhotoAssembler()
        #expect(assembler.accept(pieces[0], from: "rae", now: Self.start) == .gathering)
        #expect(assembler.accept(pieces[1], from: "sam", now: Self.start) == .gathering, "Sam's piece is Sam's")
        #expect(assembler.accept(bad, from: "rae", now: Self.start) == .refused(.digest))
        #expect(assembler.inFlight == 1, "Rae's photo was dropped; Sam's still waits")
        let other = RoadTripPhotoChunkPayload(tripID: pieces[0].tripID, photoID: pieces[0].photoID, takenAt: pieces[0].takenAt + 1,
                                              byteCount: pieces[0].byteCount, sha256: pieces[0].sha256, index: 0,
                                              count: pieces[0].count, bytes: pieces[0].bytes)
        #expect(assembler.accept(other, from: "sam", now: Self.start) == .refused(.mismatch), "a different description")
        #expect(assembler.inFlight == 0)
    }

    /// A photo whose transfer was cut off resumes when it is sent again (its missing pieces fill in), and one whose
    /// pieces stop coming is dropped after two minutes, so the next send starts it over.
    @Test func aCutOffPhotoResumesOrIsDropped() throws {
        let pieces = RoadTripPhotoChunker.chunks(of: Self.bytes(Self.chunk * 2 + 1), for: Self.photo())
        var assembler = RoadTripPhotoAssembler()
        #expect(assembler.accept(pieces[0], from: "rae", now: Self.start) == .gathering)
        #expect(assembler.accept(pieces[1], from: "rae", now: Self.start.addingTimeInterval(30)) == .gathering)
        // Sent again from the start a minute later: the first two land again, the third finishes it.
        #expect(assembler.accept(pieces[0], from: "rae", now: Self.start.addingTimeInterval(90)) == .gathering)
        guard case .complete = assembler.accept(pieces[2], from: "rae", now: Self.start.addingTimeInterval(91)) else {
            Issue.record("the re-sent photo did not finish")
            return
        }
        #expect(assembler.accept(pieces[0], from: "rae", now: Self.start) == .gathering)
        let late = Self.start.addingTimeInterval(RoadTripPhotoAssembler.staleAfter + 1)
        #expect(assembler.accept(pieces[1], from: "rae", now: late) == .gathering, "the stalled photo starts over")
        #expect(assembler.accept(pieces[2], from: "rae", now: late) == .gathering, "its first piece was dropped")
        assembler.removeAll()
        #expect(assembler.inFlight == 0, "the hangout's end drops what is incomplete")
    }

    /// At most two photos from one sender and eight in all gather at once, within 40 MiB; a new one past a bound is
    /// refused, never an eviction.
    @Test func gatheringIsBounded() {
        var assembler = RoadTripPhotoAssembler()
        let first = { (sender: String) -> RoadTripPhotoChunkPayload? in
            RoadTripPhotoChunker.chunks(of: Self.bytes(Self.chunk + 1), for: Self.photo()).first
        }
        for sender in ["a", "a"] { if let piece = first(sender) { #expect(assembler.accept(piece, from: sender, now: Self.start) == .gathering) } }
        if let piece = first("a") { #expect(assembler.accept(piece, from: "a", now: Self.start) == .refused(.busy), "two from one sender") }
        for sender in ["b", "b", "c", "c", "d", "d"] {
            if let piece = first(sender) { #expect(assembler.accept(piece, from: sender, now: Self.start) == .gathering) }
        }
        #expect(assembler.inFlight == RoadTripPhotoAssembler.maxInFlight)
        if let piece = first("e") { #expect(assembler.accept(piece, from: "e", now: Self.start) == .refused(.busy), "eight in all") }
        var big = RoadTripPhotoAssembler()
        let largest = Data(repeating: 1, count: RoadTripPhotoChunkPayload.maxPhotoBytes)
        let large = { RoadTripPhotoChunker.chunks(of: largest, for: Self.photo()).first }
        for sender in ["a", "b", "c", "d"] { if let piece = large() { #expect(big.accept(piece, from: sender, now: Self.start) == .gathering) } }
        if let piece = large() { #expect(big.accept(piece, from: "e", now: Self.start) == .refused(.busy), "40 MiB reserved") }
    }

    // MARK: The wire

    /// A photo piece rides the one road trip body as its own kind; a catch-up's held list is bounded to one roll, none
    /// twice, and is left out of the JSON when there is none (PR 2's shape unchanged).
    @Test func thePhotoKindAndTheHeldListRoundTrip() throws {
        let piece = try #require(RoadTripPhotoChunker.chunks(of: Self.bytes(2_000), for: Self.photo()).first)
        let body = RoadTripPayload.photo(piece)
        let decoded = try #require(RoadTripPayload.decoded(from: RoadTripWireTests.encoded(body)))
        #expect(decoded == body && decoded.kind == .photo && decoded.catchUp == nil)
        let held = (0..<RoadTripPayload.maxPhotosPerMember).map { _ in UUID() }
        let full = RoadTripCatchUpPayload(tripID: UUID(), isReply: false, segments: [],
                                          mapper: RoadTripWireMapperState(onCarPlay: false, isCharging: false, takeover: nil),
                                          endedAt: nil, heldPhotos: held)
        #expect(RoadTripPayload.decoded(from: try RoadTripWireTests.encoded(.catchUp(full)))?.catchUp?.heldPhotos == held)
        let over = RoadTripCatchUpPayload(tripID: UUID(), isReply: false, segments: [], mapper: full.mapper, endedAt: nil,
                                          heldPhotos: held + [UUID()])
        let twice = RoadTripCatchUpPayload(tripID: UUID(), isReply: false, segments: [], mapper: full.mapper, endedAt: nil,
                                           heldPhotos: [held[0], held[0]])
        #expect(!over.isWellFormed && !twice.isWellFormed)
        let none = RoadTripWireTests.catchUp([])
        let json = try #require(String(data: RoadTripWireTests.encoded(.catchUp(none)), encoding: .utf8))
        #expect(!json.contains("heldPhotos") && !json.contains("\"photo\""), "PR 2's catch-up keeps its shape")
        #expect(try RoadTripWireTests.encoded(body).count < RoadTripPayload.maxPlaintextBytes)
    }

    /// A full 1 MiB piece, as JSON, fits the body's byte bound with room to spare (sealed and base64'd again it stays
    /// far under the mesh's 16 MiB frame).
    @Test func aFullPieceFitsTheBodyBound() throws {
        let piece = try #require(RoadTripPhotoChunker.chunks(of: Self.bytes(Self.chunk * 3), for: Self.photo()).first)
        let json = try RoadTripWireTests.encoded(.photo(piece))
        #expect(json.count < 2 * Self.chunk && json.count < RoadTripPayload.maxPlaintextBytes)
        #expect(RoadTripPayload.decoded(from: json) != nil)
    }

    // MARK: The exchange

    /// The exchange gathers a kept friend's photo pieces and hands over the whole photo; a stranger's pieces and a
    /// decoy's are dropped; a forget drops what is incomplete.
    @Test func theExchangeGathersOnlyAKeptFriendsPhotos() throws {
        let store = makeTestStore()
        let exchange = store.meshFeatures.roadTrip
        var received: [(String, RoadTripReceivedPhoto)] = []
        var activity = 0
        exchange.onPhoto = { received.append(($0, $1)) }
        exchange.onPhotoActivity = { _ in activity += 1 }
        let rae = RoadTripMeshTests.friend("Rae", key: 41, in: store)
        let stranger = RoadTripMeshTests.friend("Stranger", key: 43, in: store, kept: false)
        let bytes = Self.bytes(Self.chunk + 50)
        let pieces = RoadTripPhotoChunker.chunks(of: bytes, for: Self.photo())
        for piece in pieces { exchange.receive(try RoadTripWireTests.encoded(.photo(piece)), from: stranger) }
        #expect(received.isEmpty && activity == 0, "a stranger's pieces are dropped")
        exchange.receive(try RoadTripWireTests.encoded(.photo(pieces[0])), from: rae)
        #expect(exchange.photosInFlight == 1 && activity == 1)
        exchange.forgetPhotoTransfers()
        #expect(exchange.photosInFlight == 0)
        for piece in pieces { exchange.receive(try RoadTripWireTests.encoded(.photo(piece)), from: rae) }
        #expect(received.count == 1 && received.first?.1.bytes == bytes && received.first?.0 == rae.fingerprint)
        store.duressSessionActive = true
        for piece in pieces { exchange.receive(try RoadTripWireTests.encoded(.photo(piece)), from: rae) }
        #expect(received.count == 1 && exchange.photosInFlight == 0, "nothing is gathered in a decoy")
        var done = false
        #expect(exchange.sendPhotos([Self.photo()], to: rae.fingerprint, bytes: { _ in bytes }, done: { done = true }) == 0)
        #expect(done, "a send that can't go says so at once")
        store.duressSessionActive = false
    }
}
