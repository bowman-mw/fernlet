// DuressRecoveryCeremonyViews.swift
// Fernlet
//
// Phase 7 (duress PIN), step 9: the in-person screens that drive `DuressRecoveryCoordinator` —
// enrolling the user's own second phone as a recovery custodian, and getting the content key back
// from it after `DuressMode.recoveryLock` has fired.
//
// WHY A QR RELAY AND NOT THE MESH. `DuressRecoveryCoordinator` is transport-free on purpose: every
// step returns the bytes to send and consumes the bytes that arrived. Carrying those bytes over the
// friend mesh would need new `PayloadType` cases plus routing inside `MeshNetworkManager` — a change
// to the radio subsystem for a ceremony that, by the locked decision, only ever happens with both
// phones in the user's own hands. So the bytes ride QR codes on screen instead: no radio, no
// pairing, no new outbound destination, and nothing in ProximityKit changes. `Docs/No-Tracking-Wall.md`
// is unaffected — a QR on a screen is not a network destination.
//
// WHY THE RELAYED PAYLOADS NEED NO SIGNATURE OR SEALING OF THEIR OWN. Every value the two small
// payloads carry is already public: the challenge is two random nonces plus the scanner's X25519
// public key (which the identity QR publishes in the clear anyway), and the response is a nonce plus
// an Ed25519 signature. The authentication lives where it already lived — the response signature is
// verified against the signing key learned from the scanned identity QR, and it covers the SCANNER'S
// key-agreement key, so a relay that substitutes its own key produces a response the real scanner
// rejects (`provenRound` verifies over its OWN local key). The two large payloads are sealed and
// signed by the coordinator before they ever reach this file. So this is a carrier, not a protocol:
// it introduces no new secret and no new trust anchor.
//
// THE ONE THING THE MISSING SEAL COSTS, STATED HONESTLY. Over the mesh, a challenge arrives inside a
// sealed envelope, so only an already-paired peer can present one. Here anyone who can put a QR in
// front of the custodian's camera while its code is on screen can present one — and the custodian
// answers with a signature over `scannerKA ‖ challengeNonce ‖ qrNonce`. That is a bounded signing
// oracle over the long-term identity key: bounded by the live display (`handleChallenge` refuses a
// challenge that does not quote the code currently shown), by the QR freshness window, by
// `clearDisplay()` on every dismissal, by the fixed-length well-formedness gate, and by
// `ProximityVerifySignature`'s domain separator, which keeps those bytes from being valid anywhere
// else. What it buys the attacker is a signature over a message they partly chose; what it costs
// them is standing at the user's elbow for the length of a ceremony the user is running on purpose.
// That is the trade this transport accepts, and it is the reason the ceremony is documented as
// in-person rather than merely defaulting to it.

import SwiftUI
import FernletFoundation
import FernletLock
import FernletUI
import ProximityKit

// MARK: - QR relay carrier

/// One hop of the in-person recovery ceremony, as it travels between two screens.
///
/// Four shapes, in the order a full recovery uses them: ``challenge`` and ``response`` complete the
/// mutual-auth round (and are the whole of an enrollment), then ``request`` and ``reply`` carry the
/// sealed recovery blob out and the sealed content key back.
///
/// Fixed-length fields throughout, checked on decode: the coordinator's transcripts are unprefixed
/// concatenations, so a wrong-length field is a malformed round rather than a different one.
///
/// `nonisolated` (the app target defaults to `MainActor`): this is an inert value carrying only
/// `Data`, and both its `Equatable` conformance and ``DuressCeremonyQR``'s codec must be usable from
/// the nonisolated contexts a decode can land in.
nonisolated enum DuressCeremonyMessage: Equatable, Sendable {
    /// Primary → custodian: the QR round being answered, the fresh challenge nonce, and the
    /// primary's X25519 public key (which the custodian's response signature must cover).
    case challenge(qrNonce: Data, challengeNonce: Data, senderKeyAgreementPublicKey: Data)
    /// Custodian → primary: the round it answered and its Ed25519 signature over the challenge
    /// transcript. This signature is the authentication for the whole exchange.
    case response(challengeNonce: Data, signature: Data)
    /// Primary → custodian: the primary's X25519 public key plus the sealed, signed recovery request
    /// the coordinator produced. Only the custodian can open it.
    case request(senderKeyAgreementPublicKey: Data, sealed: Data)
    /// Custodian → primary: the sealed, signed reply. Only the primary can open it, and it is opened
    /// from the ENROLLED custodian's key or not at all.
    case reply(sealed: Data)
}

/// Encodes a ``DuressCeremonyMessage`` into a scannable URL and back.
///
/// A caseless enum of pure functions — no state, no keys, no I/O. The URL scheme is deliberately
/// distinct from ProximityKit's `fernlet://verify`: a duress ceremony hop must never be mistaken for
/// (or replayed into) the friend-verification ceremony, and separate hosts make that a parse failure
/// rather than a judgement call.
///
/// `nonisolated` for the same reason as ``DuressCeremonyMessage``: pure functions over `Data` and
/// `URL`, with nothing to isolate.
nonisolated enum DuressCeremonyQR {
    /// Wire version. Only `1` is produced or accepted; an unknown version decodes to nil so a future
    /// build's code fails closed on an older one rather than being half-understood.
    static let version = "1"
    /// The scheme both hosts share.
    static let scheme = "fernlet"
    /// Fixed nonce length, matching `ProximityVerifySignature.nonceByteCount`.
    static let nonceByteCount = ProximityVerifySignature.nonceByteCount
    /// Fixed raw Curve25519 public-key length.
    static let publicKeyByteCount = ProximityVerifySignature.publicKeyByteCount
    /// Fixed Ed25519 signature length.
    static let signatureByteCount = 64

    /// The URL to render as a QR code, or nil when a field has the wrong length.
    static func url(for message: DuressCeremonyMessage) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        var items = [URLQueryItem(name: "v", value: version)]
        switch message {
        case .challenge(let qrNonce, let challengeNonce, let senderKeyAgreementPublicKey):
            guard qrNonce.count == nonceByteCount,
                  challengeNonce.count == nonceByteCount,
                  senderKeyAgreementPublicKey.count == publicKeyByteCount else { return nil }
            components.host = "duress-challenge"
            items += [
                URLQueryItem(name: "q", value: base64URL(qrNonce)),
                URLQueryItem(name: "c", value: base64URL(challengeNonce)),
                URLQueryItem(name: "k", value: base64URL(senderKeyAgreementPublicKey))
            ]
        case .response(let challengeNonce, let signature):
            guard challengeNonce.count == nonceByteCount,
                  signature.count == signatureByteCount else { return nil }
            components.host = "duress-response"
            items += [
                URLQueryItem(name: "c", value: base64URL(challengeNonce)),
                URLQueryItem(name: "g", value: base64URL(signature))
            ]
        case .request(let senderKeyAgreementPublicKey, let sealed):
            guard senderKeyAgreementPublicKey.count == publicKeyByteCount, !sealed.isEmpty else { return nil }
            components.host = "duress-request"
            items += [
                URLQueryItem(name: "k", value: base64URL(senderKeyAgreementPublicKey)),
                URLQueryItem(name: "d", value: base64URL(sealed))
            ]
        case .reply(let sealed):
            guard !sealed.isEmpty else { return nil }
            components.host = "duress-reply"
            items.append(URLQueryItem(name: "d", value: base64URL(sealed)))
        }
        components.queryItems = items
        return components.url
    }

    /// Decodes a scanned URL, or nil when it is not a well-formed duress ceremony hop.
    static func parse(_ url: URL) -> DuressCeremonyMessage? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              value(of: "v", in: items) == version else { return nil }
        func data(_ name: String) -> Data? { value(of: name, in: items).flatMap(decodeBase64URL) }
        switch url.host {
        case "duress-challenge":
            guard let qrNonce = data("q"), qrNonce.count == nonceByteCount,
                  let challengeNonce = data("c"), challengeNonce.count == nonceByteCount,
                  let key = data("k"), key.count == publicKeyByteCount else { return nil }
            return .challenge(qrNonce: qrNonce, challengeNonce: challengeNonce, senderKeyAgreementPublicKey: key)
        case "duress-response":
            guard let challengeNonce = data("c"), challengeNonce.count == nonceByteCount,
                  let signature = data("g"), signature.count == signatureByteCount else { return nil }
            return .response(challengeNonce: challengeNonce, signature: signature)
        case "duress-request":
            // The carrier states the frame maximum too, so an oversize payload is refused before it
            // reaches the coordinator's own `maxSealedHopBytes` guard (R3/R5).
            guard let key = data("k"), key.count == publicKeyByteCount,
                  let sealed = data("d"), !sealed.isEmpty,
                  sealed.count <= DuressRecoveryCoordinator.maxSealedHopBytes else { return nil }
            return .request(senderKeyAgreementPublicKey: key, sealed: sealed)
        case "duress-reply":
            guard let sealed = data("d"), !sealed.isEmpty,
                  sealed.count <= DuressRecoveryCoordinator.maxSealedHopBytes else { return nil }
            return .reply(sealed: sealed)
        default:
            return nil
        }
    }

    /// URL-safe, unpadded base64 — `+/=` in a query value survives most parsers but not all
    /// scanners, and the ceremony has to work off a photograph of a screen.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Inverse of ``base64URL(_:)``, restoring the padding the encoder dropped.
    private static func decodeBase64URL(_ string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }

    private static func value(of name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }
}

// MARK: - Shared ceremony chrome

/// A QR code plus its instruction, the unit both ceremony flows are built from.
///
/// Kept local rather than reusing `VerifyQRDisplaySheet`: that sheet is a self-contained modal whose
/// copy names a *friend*, and these codes are steps inside a longer flow on the user's own two
/// phones.
private struct CeremonyQRCard: View {
    let url: URL?
    let instruction: String

    var body: some View {
        VStack(spacing: 14) {
            if let url, let image = QRCodeRenderer.image(for: url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("duress.ceremony.qr")
            } else {
                Text("Couldn't create a code just now. Close this and try again.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }
            Text(instruction)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
    }
}

/// The full-width action button both flows use to advance a step.
private struct CeremonyButton: View {
    let title: String
    var identifier: String?
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(destructive ? Color.terracotta : Color.moss, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier(identifier ?? "duress.ceremony.action")
    }
}

/// Why a ceremony screen stopped, in the user's words.
///
/// Maps the coordinator's `DuressRecoveryError` cases onto copy that says what to do next. Every
/// case is a refusal before anything durable happened — that is a property of the coordinator, and
/// it is why none of this copy has to warn about a half-finished state.
private func ceremonyMessage(for error: Error) -> String {
    guard let recoveryError = error as? DuressRecoveryError else { return error.localizedDescription }
    switch recoveryError {
    case .identityUnavailable:
        return "Fernlet couldn't reach this phone's identity keys. Close this and try again."
    case .invalidQRCode:
        return "That code isn't a Fernlet code, or it has expired. Ask the other phone to show a fresh one."
    case .selfEnrollmentRefused:
        return "That's this phone's own code. A recovery device has to be a different phone."
    case .notTheEnrolledCustodian:
        return "That phone isn't the recovery device this one was set up with."
    case .noRoundInProgress:
        return "This step arrived out of order. Start again from the first code."
    case .challengeResponseRejected:
        return "The other phone's answer didn't check out. Start again from the first code."
    case .noRecoveryMaterial:
        return "This phone has no recovery device set up."
    case .malformedPayload:
        return "That code didn't scan cleanly. Try again, holding the phones steady."
    case .signatureRejected:
        return "That code wasn't signed by the phone it claims to come from."
    case .recoveryBlobUnreadable:
        return "This phone can't open that request — it isn't the recovery device for it."
    case .cryptoFailed:
        return "Something went wrong signing that step. Close this and try again."
    }
}

// MARK: - Enrollment sheet

/// Enrol a recovery device, from either side of the exchange.
///
/// Opened from ``DuressPINSetupView`` on the phone being protected, and from Settings → App lock on
/// the phone being enrolled — the two roles are genuinely different flows, so the sheet asks which
/// phone this is before it starts rather than trying to infer it.
///
/// **Both phones must be together.** There is no cloud step, no code to type out, and no way to do
/// this remotely: every hop is a code shown on one screen and read by the other camera. That is the
/// locked design, not a limitation of this screen — a remotely-enrollable custodian would turn "a
/// second key holder you can walk to" into "a second key holder anyone can reach".
struct DuressRecoveryEnrollmentSheet: View {
    /// Injected in tests to point the ceremony at a throwaway identity keychain; production leaves
    /// it nil and gets `IdentityService()`. Not a default *value*, because a `@MainActor` type can
    /// never be a default argument — the coordinator is built in `onAppear` instead.
    var coordinatorFactory: (@MainActor (FernletLockService) -> DuressRecoveryCoordinator)?

    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: DuressRecoveryCoordinator?
    @State private var role: CeremonyRole?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                content
            }
            .navigationTitle("Recovery device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                        .foregroundStyle(Color.slate)
                }
            }
        }
        .tint(Color.moss)
        .onAppear {
            guard coordinator == nil else { return }
            coordinator = coordinatorFactory?(lockService)
                ?? DuressRecoveryCoordinator(identity: IdentityService(), lockService: lockService)
        }
    }

    @ViewBuilder private var content: some View {
        if let coordinator {
            switch role {
            case .none:
                rolePicker
            case .some(.protectedPhone):
                DuressCeremonyPrimaryFlow(coordinator: coordinator, purpose: .enroll, onFinish: finish)
            case .some(.recoveryDevice):
                DuressCeremonyCustodianFlow(coordinator: coordinator, onFinish: finish)
            }
        } else {
            ProgressView().tint(Color.moss)
        }
    }

    private var rolePicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Which phone is this?")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                Text("Hold both phones together. One of them is the phone you're protecting; the other becomes its recovery device and will hold the only key that can open it again.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                CeremonyButton(title: "This is the phone I'm protecting", identifier: "duress.enroll.role.primary") {
                    role = .protectedPhone
                }
                Button("This is the recovery device") { role = .recoveryDevice }
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("duress.enroll.role.custodian")

                Text("The recovery device doesn't need its own app lock, and nothing about it is stored anywhere but on these two phones.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }

    /// Ends the sheet, clearing any code still on screen. The dismissal — not the code's own
    /// timestamp — is what makes a photographed code useless, so every exit routes through here.
    private func finish() {
        coordinator?.clearDisplay()
        dismiss()
    }

    /// Which side of the ceremony this phone is playing.
    private enum CeremonyRole { case protectedPhone, recoveryDevice }
}

// MARK: - Recovery sheet

/// Get a recovery-locked phone open again, using the enrolled recovery device.
///
/// Opened from ``AppLockSettingsView`` when `FernletLockService.isAwaitingCustodianRecovery` — the
/// state a `DuressMode.recoveryLock` leaves behind, in which the phone has no passcode at all and its
/// sealed notes are intact but unreachable.
///
/// **Warning shown up front, and it is real:** if the user set up a *new* app lock on this phone
/// after the recovery lock fired, anything sealed under that interim lock is lost when the recovered
/// key is installed. The route back to the original notes is protected; the interim ones are not.
struct DuressRecoveryReturnSheet: View {
    /// See ``DuressRecoveryEnrollmentSheet/coordinatorFactory``.
    var coordinatorFactory: (@MainActor (FernletLockService) -> DuressRecoveryCoordinator)?

    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: DuressRecoveryCoordinator?
    @State private var started = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                if let coordinator {
                    if started {
                        DuressCeremonyPrimaryFlow(coordinator: coordinator, purpose: .recover, onFinish: finish)
                    } else {
                        preamble
                    }
                } else {
                    ProgressView().tint(Color.moss)
                }
            }
            .navigationTitle("Recover this phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                        .foregroundStyle(Color.slate)
                }
            }
        }
        .tint(Color.moss)
        .onAppear {
            guard coordinator == nil else { return }
            coordinator = coordinatorFactory?(lockService)
                ?? DuressRecoveryCoordinator(identity: IdentityService(), lockService: lockService)
        }
    }

    private var preamble: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Bring your recovery device")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                Text("Your sealed journal, cycle and intimacy notes are still on this phone. Your recovery device holds the key to them. You will scan codes between the two phones, approve the request there, then choose a new passcode here.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Text("This puts back the key your recovery device was given. If you have set up a new app lock since then, anything you wrote under it will be lost — everything from before is recovered.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
                CeremonyButton(title: "Start", identifier: "duress.recover.start") { started = true }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }

    private func finish() {
        coordinator?.clearDisplay()
        dismiss()
    }
}

// MARK: - Primary (scanning) flow

/// The scanning side of both ceremonies: enrolment and recovery.
///
/// One flow with two purposes because the first three hops are identical — scan the other phone's
/// identity code, show a challenge, read the answer. Enrolment ends there (with the real passcode);
/// recovery continues with the sealed blob out and the sealed key back, and finishes by choosing a
/// new passcode.
///
/// The scanner is the side that authenticates, because it is the side with something to lose: at
/// enrolment it is about to seal its content key to the scanned device, and at recovery it is about
/// to install whatever that device hands back.
private struct DuressCeremonyPrimaryFlow: View {
    /// What this run is for.
    enum Purpose { case enroll, recover }

    let coordinator: DuressRecoveryCoordinator
    let purpose: Purpose
    let onFinish: () -> Void

    @Environment(FernletLockService.self) private var lockService

    @State private var step: Step = .scanIdentity
    @State private var challengeURL: URL?
    @State private var requestURL: URL?
    @State private var peerSigningPublicKey: Data?
    @State private var sealedReply: Data?
    /// The custodian's challenge answer, held between the scan that produced it and the passcode
    /// entry that spends it.
    @State private var pendingResponse: VerifyResponsePayload?
    @State private var passcode = ""
    @State private var newKind: FernletLockCredentialKind = .pin6
    @State private var showScanner = false
    @State private var errorMessage: String?
    /// True while an enrolment/recovery await is in flight — the one-at-a-time guard for Continue
    /// (R3: at most one in-flight task per action; a duplicate tap would spend an already-consumed
    /// round and land `.noRoundInProgress` on top of a step that had just succeeded).
    @State private var isSubmitting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.terracotta)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .fernletWrappingText()
                        .accessibilityIdentifier("duress.ceremony.error")
                }
                stepContent
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .sheet(isPresented: $showScanner) {
            VerifyQRScanSheet(
                onScanned: handleScan,
                title: "Scan the other phone",
                prompt: "Point at the code on your other phone's screen."
            )
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .scanIdentity:
            instruction("Start on your other phone: open Settings → App lock → Recovery device, choose \"This is the recovery device\", and scan the code it shows.")
            CeremonyButton(title: "Scan their code", identifier: "duress.primary.scanIdentity") { showScanner = true }
        case .showChallenge:
            CeremonyQRCard(url: challengeURL, instruction: "Have your other phone scan this code.")
            CeremonyButton(title: "They've scanned it", identifier: "duress.primary.challengeShown") {
                step = .scanResponse
            }
        case .scanResponse:
            instruction("Your other phone is now showing an answer code. Scan it.")
            CeremonyButton(title: "Scan their answer", identifier: "duress.primary.scanResponse") { showScanner = true }
        case .enterPasscode:
            enterPasscodeStep
        case .showRequest:
            CeremonyQRCard(url: requestURL, instruction: "Have your other phone scan this code, then approve the request there.")
            CeremonyButton(title: "They've approved it", identifier: "duress.primary.requestShown") {
                step = .scanReply
            }
        case .scanReply:
            instruction("Scan the code your other phone is showing now.")
            CeremonyButton(title: "Scan their reply", identifier: "duress.primary.scanReply") { showScanner = true }
        case .chooseNewPasscode:
            chooseNewPasscodeStep
        case .done(let message):
            instruction(message)
            CeremonyButton(title: "Done", identifier: "duress.primary.done") { onFinish() }
        }
    }

    // MARK: Steps needing input

    private var enterPasscodeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your passcode")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Your real passcode — the one that opens your data. Fernlet uses it to unlock the key it is about to seal to your recovery device, and the key never leaves this phone unsealed.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            credentialField(text: $passcode, placeholder: "Passcode", identifier: "duress.primary.passcode") {
                completeEnrollment()
            }
        }
    }

    private var chooseNewPasscodeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a new passcode")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Your notes come back under this new passcode. Biometric unlock is off until you turn it on again.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            VStack(spacing: 12) {
                kindPicker(.pin4, title: "4-digit PIN")
                kindPicker(.pin6, title: "6-digit PIN")
                kindPicker(.alphanumeric, title: "Password")
            }
            credentialField(text: $passcode, placeholder: "New passcode", identifier: "duress.primary.newPasscode") {
                completeRecovery()
            }
        }
    }

    private func kindPicker(_ kind: FernletLockCredentialKind, title: String) -> some View {
        Button {
            newKind = kind
            passcode = ""
        } label: {
            HStack(spacing: 14) {
                Image(systemName: kind == newKind ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(kind == newKind ? Color.moss : Color.slate.opacity(0.4))
                Text(title)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                Spacer()
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A secure field plus its submit button. Deliberately not the numeric pad: this flow is a
    /// multi-step ceremony on a scrolling screen, and an auto-submitting pad would fire mid-scroll.
    private func credentialField(
        text: Binding<String>,
        placeholder: String,
        identifier: String,
        submit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SecureField(placeholder, text: text)
                .textContentType(.password)
                .sheetTextInput()
                .accessibilityIdentifier(identifier)
            CeremonyButton(title: "Continue", identifier: identifier + ".continue") { submit() }
                .disabled(isSubmitting)
        }
    }

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.fernlet(.body))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    // MARK: Ceremony steps

    private func handleScan(_ url: URL) {
        errorMessage = nil
        switch step {
        case .scanIdentity:
            do {
                guard let payload = ProximityVerifyQR.parse(url) else {
                    throw DuressRecoveryError.invalidQRCode
                }
                let challenge = purpose == .enroll
                    ? try coordinator.beginCustodianEnrollment(scannedURL: url)
                    : try coordinator.beginRecovery(scannedURL: url)
                peerSigningPublicKey = payload.signingPublicKey
                challengeURL = DuressCeremonyQR.url(for: .challenge(
                    qrNonce: challenge.qrNonce,
                    challengeNonce: challenge.challengeNonce,
                    senderKeyAgreementPublicKey: coordinator.localKeyAgreementPublicKey
                ))
                step = .showChallenge
            } catch {
                errorMessage = ceremonyMessage(for: error)
            }
        case .scanResponse:
            guard case .response(let challengeNonce, let signature)? = DuressCeremonyQR.parse(url) else {
                errorMessage = ceremonyMessage(for: DuressRecoveryError.malformedPayload)
                return
            }
            let response = VerifyResponsePayload(challengeNonce: challengeNonce, signature: signature)
            if purpose == .enroll {
                pendingResponse = response
                step = .enterPasscode
            } else {
                makeRecoveryRequest(response: response)
            }
        case .scanReply:
            guard case .reply(let sealed)? = DuressCeremonyQR.parse(url) else {
                errorMessage = ceremonyMessage(for: DuressRecoveryError.malformedPayload)
                return
            }
            sealedReply = sealed
            step = .chooseNewPasscode
        default:
            break
        }
    }

    private func makeRecoveryRequest(response: VerifyResponsePayload) {
        guard let peerSigningPublicKey else { return }
        do {
            let sealed = try coordinator.makeRecoveryRequest(
                response: response,
                senderSigningPublicKey: peerSigningPublicKey
            )
            requestURL = DuressCeremonyQR.url(for: .request(
                senderKeyAgreementPublicKey: coordinator.localKeyAgreementPublicKey,
                sealed: sealed
            ))
            step = .showRequest
        } catch {
            errorMessage = ceremonyMessage(for: error)
        }
    }

    private func completeEnrollment() {
        guard let peerSigningPublicKey, let response = pendingResponse else { return }
        guard !isSubmitting else { return }
        isSubmitting = true
        let entered = passcode
        // Captured BEFORE the call: `enrollRecoveryCustodian` returns silently on a DURESS match —
        // it presents the decoy and seals nothing — so "no error was thrown" is not proof that an
        // enrolment happened. Comparing the blob is, and it stays exact when a custodian was already
        // enrolled (where `hasRecoveryCustodian` would have been true either way).
        let blobBefore = lockService.custodianRecoveryBlob
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await coordinator.completeCustodianEnrollment(
                    response: response,
                    senderSigningPublicKey: peerSigningPublicKey,
                    passcode: entered
                )
                passcode = ""
                guard lockService.hasRecoveryCustodian,
                      lockService.custodianRecoveryBlob != blobBefore else {
                    errorMessage = "That passcode didn't set up a recovery device. Check it and try again."
                    step = .scanIdentity
                    return
                }
                step = .done("This phone is set up. Your other phone now holds the only key that can open it again — keep it somewhere you can reach.")
            } catch {
                passcode = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    private func completeRecovery() {
        guard let sealedReply else { return }
        guard !isSubmitting else { return }
        isSubmitting = true
        let credential = FernletLockCredential(kind: newKind, rawValue: passcode)
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                // `.appLockSettings`, deliberately, and NOT `.privateHub`: the recovery runs from a
                // settings screen, and that scope never receives the content key. The rebuilt lock
                // is opened the normal way — the Private tab asks for the new passcode.
                let outcome = try await coordinator.completeRecovery(
                    sealedReply: sealedReply,
                    credential: credential,
                    grantingScope: .appLockSettings
                )
                passcode = ""
                switch outcome {
                case .unlockReestablished:
                    step = .done("Your notes are back. Open the Private tab and enter your new passcode to see them — Face ID is off until you turn it back on in App lock.")
                case .destructionRequested:
                    step = .done("Your recovery device asked Fernlet to let this data go rather than return it. Nothing was recovered. You can start fresh from Settings → App lock.")
                }
            } catch {
                passcode = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The ordered screens of the scanning side. Strictly forward; an error re-shows the step that
    /// raised it rather than unwinding, because every refusal happens before anything durable.
    private enum Step: Equatable {
        case scanIdentity
        case showChallenge
        case scanResponse
        /// Enrolment only: the real passcode that releases the key into the sealing closure.
        case enterPasscode
        /// Recovery only.
        case showRequest
        /// Recovery only.
        case scanReply
        /// Recovery only: the NEW passcode the recovered key is re-locked under.
        case chooseNewPasscode
        case done(String)
    }
}

// MARK: - Custodian (displaying) flow

/// The displaying side of both ceremonies, on the phone acting as somebody's recovery device.
///
/// Shows this phone's identity code, answers the challenge, and — if the other phone is recovering
/// rather than enrolling — reads its sealed request, shows the human who is asking, and returns
/// either the key or a refusal. The recovery blob is not opened until the human says yes, so "I said
/// no" and "I never had that key in memory" stay the same statement.
private struct DuressCeremonyCustodianFlow: View {
    let coordinator: DuressRecoveryCoordinator
    let onFinish: () -> Void

    @State private var step: Step = .showIdentity
    @State private var identityURL: URL?
    @State private var responseURL: URL?
    @State private var replyURL: URL?
    @State private var requesterFingerprint: String?
    @State private var showScanner = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.terracotta)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .fernletWrappingText()
                        .accessibilityIdentifier("duress.ceremony.error")
                }
                stepContent
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .onAppear {
            guard identityURL == nil else { return }
            identityURL = coordinator.makeDisplayURL()
        }
        .sheet(isPresented: $showScanner) {
            VerifyQRScanSheet(
                onScanned: handleScan,
                title: "Scan the other phone",
                prompt: "Point at the code on the other phone's screen."
            )
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .showIdentity:
            CeremonyQRCard(url: identityURL, instruction: "Have the other phone scan this code.")
            CeremonyButton(title: "They've scanned it", identifier: "duress.custodian.identityShown") {
                step = .scanChallenge
            }
        case .scanChallenge:
            instruction("The other phone is now showing a code of its own. Scan it.")
            CeremonyButton(title: "Scan their code", identifier: "duress.custodian.scanChallenge") { showScanner = true }
        case .showResponse:
            CeremonyQRCard(url: responseURL, instruction: "Have the other phone scan this answer.")
            instruction("If that phone is being set up, you're done. If it is recovering, it will show one more code.")
            CeremonyButton(title: "Done", identifier: "duress.custodian.done") { onFinish() }
            Button("They're recovering — scan their next code") { step = .scanRequest }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("duress.custodian.continueToRecovery")
        case .scanRequest:
            instruction("Scan the request code the other phone is showing.")
            CeremonyButton(title: "Scan their request", identifier: "duress.custodian.scanRequest") { showScanner = true }
        case .decide:
            decideStep
        case .showReply:
            CeremonyQRCard(url: replyURL, instruction: "Have the other phone scan this code to finish.")
            CeremonyButton(title: "Done", identifier: "duress.custodian.replyDone") { onFinish() }
        }
    }

    private var decideStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Return the key?")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            if let requesterFingerprint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Asking phone")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                    Text(requesterFingerprint)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.bark)
                        .accessibilityIdentifier("duress.custodian.fingerprint")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            }
            Text("Only say yes if that phone is in front of you and it is the one you set this up with. Saying yes hands back the key to everything it had sealed.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            CeremonyButton(title: "Return the key", identifier: "duress.custodian.approve") { answer(.returnKey) }
            CeremonyButton(title: "Refuse and tell it to let go", identifier: "duress.custodian.refuse", destructive: true) {
                answer(.destroy)
            }
        }
    }

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.fernlet(.body))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    private func handleScan(_ url: URL) {
        errorMessage = nil
        switch step {
        case .scanChallenge:
            guard case .challenge(let qrNonce, let challengeNonce, let senderKey)? = DuressCeremonyQR.parse(url) else {
                errorMessage = ceremonyMessage(for: DuressRecoveryError.malformedPayload)
                return
            }
            guard let response = coordinator.handleChallenge(
                VerifyChallengePayload(qrNonce: qrNonce, challengeNonce: challengeNonce),
                senderKeyAgreementPublicKey: senderKey
            ) else {
                errorMessage = ceremonyMessage(for: DuressRecoveryError.challengeResponseRejected)
                return
            }
            responseURL = DuressCeremonyQR.url(for: .response(
                challengeNonce: response.challengeNonce,
                signature: response.signature
            ))
            step = .showResponse
        case .scanRequest:
            guard case .request(let senderKey, let sealed)? = DuressCeremonyQR.parse(url) else {
                errorMessage = ceremonyMessage(for: DuressRecoveryError.malformedPayload)
                return
            }
            do {
                let summary = try coordinator.openRecoveryRequest(sealed, from: senderKey)
                requesterFingerprint = summary.requesterFingerprint
                step = .decide
            } catch {
                errorMessage = ceremonyMessage(for: error)
            }
        default:
            break
        }
    }

    private func answer(_ decision: DuressRecoveryDecision) {
        do {
            let sealed = try coordinator.answerPendingRecoveryRequest(decision)
            replyURL = DuressCeremonyQR.url(for: .reply(sealed: sealed))
            step = .showReply
        } catch {
            errorMessage = ceremonyMessage(for: error)
        }
    }

    /// The ordered screens of the displaying side. ``showResponse`` is the fork: an enrolment ends
    /// there, a recovery continues into the request.
    private enum Step: Equatable {
        case showIdentity
        case scanChallenge
        case showResponse
        case scanRequest
        case decide
        case showReply
    }
}
