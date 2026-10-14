import Foundation

/// Access to the device key. The iOS implementation keeps the secret wrapped by the Secure
/// Enclave and asks for Face ID / passcode before every signature.
public protocol KeyVault: Sendable {
    var hasKey: Bool { get async }
    /// Public key for `path` if it can be returned without unlocking the secret.
    func cachedPublicKey(for path: BIP32Path) async -> Data?
    /// Public key that would sign a request for `path` naming `expectedPublicKey`, if known without
    /// unlocking. A vault with several secrets routes by the expected key.
    func cachedPublicKey(for path: BIP32Path, expecting expectedPublicKey: Data?) async -> Data?
    /// Unlocks the secret (may prompt for biometrics), derives the key and caches its public key.
    func derivePublicKey(for path: BIP32Path, reason: String) async throws -> Data
    /// Unlocks the secret, checks `expectedPublicKey` (if given) and signs `digest` with ed25519.
    func sign(digest: Data, path: BIP32Path, expectedPublicKey: Data?, reason: String) async throws -> SignResult
}

extension KeyVault {
    public func cachedPublicKey(for path: BIP32Path, expecting expectedPublicKey: Data?) async -> Data? {
        await cachedPublicKey(for: path)
    }
}

public struct SignResult: Sendable {
    public var signature: Data
    public var publicKey: Data

    public init(signature: Data, publicKey: Data) {
        self.signature = signature
        self.publicKey = publicKey
    }
}

public enum SignerError: Error, Equatable, CustomStringConvertible {
    case publicKeyMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .publicKeyMismatch(expected, actual):
            return "request is for key \(expected) but this signer's key at that path is \(actual)"
        }
    }
}

/// Key vault holding the secret in memory. Used by the simulator and tests.
public final class InMemoryKeyVault: KeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private var material: KeyMaterial?
    private var cache: [BIP32Path: Data] = [:]

    public init(material: KeyMaterial?) {
        self.material = material
    }

    public var hasKey: Bool { lock.withLock { material != nil } }

    public func cachedPublicKey(for path: BIP32Path) async -> Data? {
        lock.withLock { cache[path] }
    }

    public func derivePublicKey(for path: BIP32Path, reason: String) async throws -> Data {
        try lock.withLock {
            guard let material else { throw KeyError.noKey }
            let publicKey = try material.privateKey(for: path).publicKey.rawRepresentation
            cache[path] = publicKey
            return publicKey
        }
    }

    public func sign(digest: Data, path: BIP32Path, expectedPublicKey: Data?, reason: String) async throws -> SignResult {
        try lock.withLock {
            guard let material else { throw KeyError.noKey }
            let key = try material.privateKey(for: path)
            let publicKey = key.publicKey.rawRepresentation
            if let expectedPublicKey, expectedPublicKey != publicKey {
                throw SignerError.publicKeyMismatch(
                    expected: PublicKey.ed25519(expectedPublicKey).description,
                    actual: PublicKey.ed25519(publicKey).description)
            }
            // Cached only after the check: a failed request must not count as sharing the key.
            cache[path] = publicKey
            return SignResult(signature: try key.signature(for: digest), publicKey: publicKey)
        }
    }
}

/// What the user is asked to approve.
public struct ApprovalRequest: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case transaction
        case delegateAction
        case message
        case publicKey
    }

    public var id: UUID
    public var kind: Kind
    public var path: BIP32Path
    public var transport: String
    public var display: RequestDisplay
    /// The NEAR account the request acts for (transaction signer or meta-transaction sender).
    public var signerId: String?
    /// The ed25519 key the payload says must sign it, if it names one.
    public var publicKey: Data?
    public var receivedAt: Date
    /// Approving unlocks the key, with Face ID or the passcode. Sharing an account the phone
    /// already knows does not: its public key is stored.
    public var needsUnlock: Bool

    public init(id: UUID = UUID(), kind: Kind, path: BIP32Path, transport: String, display: RequestDisplay,
                signerId: String? = nil, publicKey: Data? = nil, receivedAt: Date = Date(), needsUnlock: Bool = true) {
        self.id = id
        self.kind = kind
        self.path = path
        self.transport = transport
        self.display = display
        self.signerId = signerId
        self.publicKey = publicKey
        self.receivedAt = receivedAt
        self.needsUnlock = needsUnlock
    }
}

/// Shows a request to the user and returns their decision. Implementations must return
/// `false` promptly when the calling task is cancelled (for example when the host disconnects).
public protocol ApprovalPresenter: Sendable {
    func requestApproval(_ request: ApprovalRequest) async -> Bool
}

/// Events for UI and logs.
public enum SignerEvent: Sendable {
    /// A large request is still arriving.
    case receiving(ReceiveProgress)
    /// It arrived completely, was cancelled, or the host gave up.
    case receiveEnded(UUID)
    case requestStarted(ApprovalRequest)
    case requestFinished(HistoryRecord)
}

/// Decodes requests, asks for approval, signs and records history.
public actor SignerService {
    public enum SignKind: Sendable {
        case transaction
        case nep413
        case nep366

        var historyKind: HistoryRecord.Kind {
            switch self {
            case .transaction: return .transaction
            case .nep413: return .message
            case .nep366: return .delegateAction
            }
        }
    }

    private let vault: KeyVault
    private let presenter: ApprovalPresenter
    private let history: HistoryStore
    private let onEvent: (@Sendable (SignerEvent) -> Void)?
    private var busy = false
    /// When true, public key requests for already exported paths are answered without a prompt,
    /// with or without the display flag (near-ledger-rs, for near-cli-rs, sets it before every
    /// signature). When false, every request asks, as the setting promises.
    private var autoShareKnownPublicKeys = false
    /// (path, key) pairs that already failed the key check. Derivation is deterministic, so a
    /// retry is refused without prompting, and without caching (and so sharing) the derived key.
    private var knownMismatches: Set<String> = []

    public init(vault: KeyVault, presenter: ApprovalPresenter, history: HistoryStore,
                onEvent: (@Sendable (SignerEvent) -> Void)? = nil) {
        self.vault = vault
        self.presenter = presenter
        self.history = history
        self.onEvent = onEvent
    }

    public func setAutoShareKnownPublicKeys(_ enabled: Bool) {
        autoShareKnownPublicKeys = enabled
    }

    /// Forgets remembered key mismatches; call when the keys behind each path may have changed
    /// (a wallet was added, removed or switched).
    public func clearKnownMismatches() {
        knownMismatches.removeAll()
    }

    // MARK: Receiving

    private var cancelledReceives: Set<UUID> = []

    public func reportReceiving(_ progress: ReceiveProgress) {
        onEvent?(.receiving(progress))
    }

    public func endReceiving(_ id: UUID) {
        cancelledReceives.remove(id)
        onEvent?(.receiveEnded(id))
    }

    /// Asks the session to refuse the next chunk of request `id`, which stops the host.
    public func cancelReceiving(_ id: UUID) {
        cancelledReceives.insert(id)
    }

    func takeCancelledReceive(_ id: UUID) -> Bool {
        cancelledReceives.remove(id) != nil
    }

    func recordCancelledReceive(_ progress: ReceiveProgress, kind: SignKind) async {
        await record(HistoryRecord(kind: kind.historyKind, outcome: .rejected, transport: progress.transport,
                                   path: "", title: "Request cancelled while receiving",
                                   failureReason: "Cancelled after \(NearFormat.byteSize(progress.received)) had arrived."))
    }

    // MARK: Public key

    public func publicKey(path: BIP32Path, display: Bool, transport: String) async -> Result<Data, StatusWord> {
        guard await vault.hasKey else { return .failure(.locked) }
        let cached = await vault.cachedPublicKey(for: path)
        if let cached, autoShareKnownPublicKeys { return .success(cached) }

        guard !busy else { return .failure(.busy) }
        busy = true
        defer { busy = false }

        let request = ApprovalRequest(
            kind: .publicKey, path: path, transport: transport,
            display: RequestRenderer.render(publicKeyRequest: path,
                                            publicKey: cached.map { PublicKey.ed25519($0).description }),
            needsUnlock: cached == nil)
        onEvent?(.requestStarted(request))
        let approved = await presenter.requestApproval(request)
        guard approved, !Task.isCancelled else {
            await record(HistoryRecord(kind: .publicKey, outcome: .rejected, transport: transport,
                                       path: path.description, title: request.display.title,
                                       publicKey: cached.map { PublicKey.ed25519($0).description },
                                       symbol: .publicKey))
            return .failure(.userRejected)
        }
        do {
            if let cached { return .success(cached) }
            // Only first exports of a path are recorded, so the history stays about signatures.
            let key = try await vault.derivePublicKey(for: path, reason: "Export the public key for \(path)")
            await record(HistoryRecord(kind: .publicKey, outcome: .approved, transport: transport,
                                       path: path.description, title: request.display.title,
                                       publicKey: PublicKey.ed25519(key).description, symbol: .publicKey))
            return .success(key)
        } catch KeyError.authenticationCancelled {
            await record(HistoryRecord(kind: .publicKey, outcome: .rejected, transport: transport,
                                       path: path.description, title: request.display.title,
                                       failureReason: KeyError.authenticationCancelled.description, symbol: .publicKey))
            return .failure(.userRejected)
        } catch {
            await record(HistoryRecord(kind: .publicKey, outcome: .failed, transport: transport,
                                       path: path.description, title: request.display.title,
                                       failureReason: SignerService.readable(error), symbol: .publicKey))
            return .failure(.locked)
        }
    }

    // MARK: Signing

    public func sign(kind: SignKind, path: BIP32Path, payload: Data, transport: String) async -> Result<Data, StatusWord> {
        guard await vault.hasKey else { return .failure(.locked) }
        guard !busy else { return .failure(.busy) }
        busy = true
        defer { busy = false }

        // 1. Decode. Nothing that cannot be fully decoded is ever shown for approval (no blind signing).
        let prepared: PreparedRequest
        do {
            prepared = try PreparedRequest(kind: kind, payload: payload)
        } catch {
            // Refused without a prompt, so a host could send these endlessly: keep the hash and size,
            // not the bytes.
            await record(HistoryRecord(kind: kind.historyKind, outcome: .failed, transport: transport,
                                       path: path.description, title: "Undecodable request refused",
                                       hash: Base58.encode(Data(SHA256.hash(data: payload))),
                                       failureReason: "\(error) (\(NearFormat.byteSize(payload.count)))",
                                       payloadSize: payload.count), automatic: true)
            return .failure(.parseFailed)
        }

        // 2. Refuse early if the request names a key that is not ours.
        let cached = await vault.cachedPublicKey(for: path, expecting: prepared.expectedPublicKey)
        let mismatchKey = prepared.expectedPublicKey.map { "\(path)|\($0.hexString)" }
        if let mismatchKey, knownMismatches.contains(mismatchKey) {
            await record(prepared.historyRecord(outcome: .failed, transport: transport, path: path,
                                                payload: payload, keepPayload: false, publicKey: nil, signature: nil,
                                                failureReason: "request is for a key that is not this signer's key at \(path)"),
                         automatic: true)
            return .failure(.publicKeyMismatch)
        }
        if let expected = prepared.expectedPublicKey, let cached, cached != expected {
            await record(prepared.historyRecord(outcome: .failed, transport: transport, path: path,
                                                payload: payload, keepPayload: false, publicKey: nil, signature: nil,
                                                failureReason: SignerError.publicKeyMismatch(
                                                    expected: PublicKey.ed25519(expected).description,
                                                    actual: PublicKey.ed25519(cached).description).description),
                         automatic: true)
            return .failure(.publicKeyMismatch)
        }

        // 3. Ask the user.
        let request = ApprovalRequest(kind: prepared.approvalKind, path: path, transport: transport,
                                      display: prepared.display, signerId: prepared.signerId.map { NearFormat.visible($0) },
                                      publicKey: prepared.expectedPublicKey)
        onEvent?(.requestStarted(request))
        let approved = await presenter.requestApproval(request)
        guard approved, !Task.isCancelled else {
            // The bytes are kept only when the user turned the request down: a host that sends
            // requests and disconnects must not fill the history with its payloads.
            let disconnected = Task.isCancelled
            await record(prepared.historyRecord(outcome: .rejected, transport: transport, path: path,
                                                payload: payload, keepPayload: !disconnected, publicKey: cached, signature: nil,
                                                failureReason: disconnected ? "host disconnected" : nil))
            return .failure(.userRejected)
        }

        // 4. Unlock and sign.
        do {
            let result = try await vault.sign(digest: prepared.digest, path: path,
                                              expectedPublicKey: prepared.expectedPublicKey,
                                              reason: prepared.display.title)
            await record(prepared.historyRecord(outcome: .approved, transport: transport, path: path,
                                                payload: payload, publicKey: result.publicKey,
                                                signature: result.signature, failureReason: nil))
            return .success(result.signature)
        } catch KeyError.authenticationCancelled {
            await record(prepared.historyRecord(outcome: .rejected, transport: transport, path: path,
                                                payload: payload, publicKey: cached, signature: nil,
                                                failureReason: KeyError.authenticationCancelled.description))
            return .failure(.userRejected)
        } catch let error as SignerError {
            if let mismatchKey { knownMismatches.insert(mismatchKey) }
            await record(prepared.historyRecord(outcome: .failed, transport: transport, path: path,
                                                payload: payload, publicKey: nil, signature: nil,
                                                failureReason: error.description))
            return .failure(.publicKeyMismatch)
        } catch {
            await record(prepared.historyRecord(outcome: .failed, transport: transport, path: path,
                                                payload: payload, publicKey: nil, signature: nil,
                                                failureReason: SignerService.readable(error)))
            return .failure(.locked)
        }
    }

    /// The message a person can read (`UserFacingError`, such as the vault's), not the case name.
    static func readable(_ error: Error) -> String {
        (error as? UserFacingError)?.userMessage ?? String(describing: error)
    }

    /// - Parameter automatic: a request refused without being shown. A host can send many, so
    ///   they are written to disk in batches.
    private func record(_ entry: HistoryRecord, automatic: Bool = false) async {
        try? await history.append(entry, deferWrite: automatic)
        onEvent?(.requestFinished(entry))
    }
}

/// An error with a message written for the person using the app. Signing results and the history
/// show it instead of the error's case name.
public protocol UserFacingError: Error {
    var userMessage: String { get }
}

/// A decoded signing request.
public struct PreparedRequest: Sendable {
    public enum Content: Sendable {
        case transaction(Transaction)
        case delegateAction(DelegateAction)
        case message(NEP413Payload)
    }

    public var content: Content
    public var digest: Data
    public var display: RequestDisplay

    public init(kind: SignerService.SignKind, payload: Data) throws {
        switch kind {
        case .transaction:
            let tx = try Transaction.decode(payload)
            // Fail closed if decoding was lenient anywhere: what is shown must re-encode to exactly
            // the bytes that are signed.
            guard tx.borsh == payload else { throw BorshError.nonCanonical }
            digest = SigningDigest.transaction(payload)
            content = .transaction(tx)
            display = RequestRenderer.render(transaction: tx, hash: digest).sanitized()
        case .nep366:
            let action = try DelegateAction.decode(payload)
            guard action.borsh == payload else { throw BorshError.nonCanonical }
            digest = SigningDigest.delegateAction(payload)
            content = .delegateAction(action)
            display = RequestRenderer.render(delegateAction: action, digest: digest).sanitized()
        case .nep413:
            let message = try NEP413Payload.decode(payload)
            guard message.borsh == payload else { throw BorshError.nonCanonical }
            digest = SigningDigest.nep413(payload)
            content = .message(message)
            display = RequestRenderer.render(message: message, digest: digest).sanitized()
        }
    }

    /// Re-decodes a history record's payload for the details screen.
    public init?(record: HistoryRecord) {
        let kind: SignerService.SignKind
        switch record.kind {
        case .transaction: kind = .transaction
        case .delegateAction: kind = .nep366
        case .message: kind = .nep413
        case .publicKey: return nil
        }
        guard let prepared = try? PreparedRequest(kind: kind, payload: record.payload) else { return nil }
        self = prepared
    }

    var approvalKind: ApprovalRequest.Kind {
        switch content {
        case .transaction: return .transaction
        case .delegateAction: return .delegateAction
        case .message: return .message
        }
    }

    /// The account the request acts for.
    public var signerId: String? {
        switch content {
        case let .transaction(tx): return tx.signerId
        case let .delegateAction(action): return action.senderId
        case .message: return nil
        }
    }

    /// Accounts this request creates and the keys it gives them: CreateAccount + AddKey on a
    /// subaccount of the signer (the only kind a transaction can create), or `create_account` on
    /// the `near` / `testnet` registrar. Calls to other contracts are ignored: they prove nothing.
    public var createdAccounts: [(accountId: String, publicKey: PublicKey)] {
        guard case let .transaction(tx) = content else { return [] }
        var result: [(accountId: String, publicKey: PublicKey)] = []
        if tx.receiverId.hasSuffix(".\(tx.signerId)"),
           tx.actions.contains(where: { if case .createAccount = $0 { return true } else { return false } }) {
            for case let .addKey(publicKey, _) in tx.actions { result.append((tx.receiverId, publicKey)) }
        }
        for case let .functionCall(call) in tx.actions
            where call.methodName == "create_account" && (tx.receiverId == "near" || tx.receiverId == "testnet") {
            guard let args = try? JSONSerialization.jsonObject(with: call.args) as? [String: Any],
                  let accountId = args["new_account_id"] as? String,
                  let key = (args["new_public_key"] as? String).flatMap(PublicKey.init(string:)) else { continue }
            result.append((accountId, key))
        }
        return result
    }

    /// The ed25519 key the payload says must sign it.
    var expectedPublicKey: Data? {
        let key: PublicKey
        switch content {
        case let .transaction(tx): key = tx.publicKey
        case let .delegateAction(action): key = action.publicKey
        case .message: return nil
        }
        if case let .ed25519(bytes) = key { return bytes }
        // A non-ed25519 key can never match this signer.
        return Data()
    }

    /// - Parameter keepPayload: false for requests refused without being shown.
    func historyRecord(outcome: HistoryRecord.Outcome, transport: String, path: BIP32Path, payload: Data,
                       keepPayload: Bool = true, publicKey: Data?, signature: Data?, failureReason: String?) -> HistoryRecord {
        var signerId: String?
        var receiverId: String?
        let kind: HistoryRecord.Kind
        switch content {
        case let .transaction(tx):
            kind = .transaction
            signerId = tx.signerId
            receiverId = tx.receiverId
        case let .delegateAction(action):
            kind = .delegateAction
            signerId = action.senderId
            receiverId = action.receiverId
        case let .message(message):
            kind = .message
            receiverId = message.recipient
        }
        let network = signerId.flatMap(NearFormat.inferredNetwork) ?? receiverId.flatMap(NearFormat.inferredNetwork)
        // Shown in the history list: hidden characters are made visible like on the approval screen.
        return HistoryRecord(
            kind: kind, outcome: outcome, transport: transport, path: path.description,
            title: display.title, signerId: signerId.map { NearFormat.visible($0) },
            receiverId: receiverId.map { NearFormat.visible($0) }, network: network,
            hash: Base58.encode(digest),
            publicKey: publicKey.map { PublicKey.ed25519($0).description },
            signature: signature.map { Signature.ed25519($0).description },
            payload: keepPayload ? payload : Data(), failureReason: failureReason, symbol: display.symbol,
            payloadSize: payload.count)
    }
}
