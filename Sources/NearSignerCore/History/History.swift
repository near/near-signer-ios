import Foundation

/// One entry in the signing history. Every request that reached the user (or was refused
/// automatically) is recorded, whether it was approved, rejected or failed.
public struct HistoryRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case transaction
        case delegateAction
        case message
        case publicKey
    }

    public enum Outcome: String, Codable, Sendable {
        case approved
        case rejected
        case failed
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var outcome: Outcome
    /// Transport the request arrived on, for example "Bluetooth".
    public var transport: String
    public var path: String
    /// One-line summary, for example "Transfer 1.5 NEAR to bob.near".
    public var title: String
    public var signerId: String?
    public var receiverId: String?
    public var network: String?
    /// NEAR transaction hash (base58) for transactions, or the signed digest otherwise.
    public var hash: String?
    /// `ed25519:<base58>` public key that signed (or would have signed).
    public var publicKey: String?
    /// `ed25519:<base58>` signature, present only for approved requests.
    public var signature: String?
    /// Raw request payload (Borsh), kept so the details screen can decode it again. Empty for
    /// requests refused without being shown, and for old ones beyond the storage budget.
    public var payload: Data
    /// Size of the original payload, also when it is not kept.
    public var payloadSize: Int?
    public var failureReason: String?
    /// Icon category of the request. Absent in records written by older versions.
    public var symbol: DisplaySymbol?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        outcome: Outcome,
        transport: String,
        path: String,
        title: String,
        signerId: String? = nil,
        receiverId: String? = nil,
        network: String? = nil,
        hash: String? = nil,
        publicKey: String? = nil,
        signature: String? = nil,
        payload: Data = Data(),
        failureReason: String? = nil,
        symbol: DisplaySymbol? = nil,
        payloadSize: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.outcome = outcome
        self.transport = transport
        self.path = path
        self.title = title
        self.signerId = signerId
        self.receiverId = receiverId
        self.network = network
        self.hash = hash
        self.publicKey = publicKey
        self.signature = signature
        self.payload = payload
        self.failureReason = failureReason
        self.symbol = symbol
        self.payloadSize = payloadSize ?? payload.count
    }
}

/// Signing history persisted as a JSON file. The iOS app passes `.completeFileProtection`
/// so the file is encrypted with a key that is unavailable while the device is locked.
public actor HistoryStore {
    public nonisolated let fileURL: URL?
    private let writeOptions: Data.WritingOptions
    private let maxRecords: Int
    private var records: [HistoryRecord]

    private let maxPayloadBytes: Int
    private var pendingWrite: Task<Void, Never>?
    /// How long a deferred write waits, so a burst of automatic refusals costs one write.
    private let writeDelay: UInt64 = 2_000_000_000

    /// - Parameters:
    ///   - fileURL: nil keeps the history in memory only.
    ///   - maxPayloadBytes: raw payloads are kept for the newest records up to this total; older
    ///     records keep their hash, title and fields but not the bytes (contract code is large).
    public init(fileURL: URL?, writeOptions: Data.WritingOptions = [.atomic], maxRecords: Int = 2000,
                maxPayloadBytes: Int = 16 * 1024 * 1024) {
        self.fileURL = fileURL
        self.writeOptions = writeOptions
        self.maxRecords = maxRecords
        self.maxPayloadBytes = maxPayloadBytes
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? HistoryStore.decoder.decode([HistoryRecord].self, from: data) {
            self.records = decoded
        } else {
            self.records = []
        }
    }

    /// Reads the file again. The iOS app calls it once protected data is available: a launch while
    /// the phone is locked cannot read a file with complete protection.
    public func reload() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? HistoryStore.decoder.decode([HistoryRecord].self, from: data) else { return }
        records = decoded
    }

    /// Newest first.
    public func all() -> [HistoryRecord] { records }

    public func record(id: UUID) -> HistoryRecord? { records.first { $0.id == id } }

    /// - Parameter deferWrite: writes the file a moment later, together with whatever else
    ///   arrives meanwhile (for automatic refusals, which a host can send in bulk).
    public func append(_ record: HistoryRecord, deferWrite: Bool = false) throws {
        records.insert(record, at: 0)
        // Over the limit, the oldest refused or failed requests go first: a host sending junk must
        // not be able to push approved signatures out of the history.
        while records.count > maxRecords {
            if let index = records.lastIndex(where: { $0.outcome != .approved }) {
                records.remove(at: index)
            } else {
                records.removeLast()
            }
        }
        // Over the payload budget, refused and failed requests lose their bytes first, oldest
        // first, then approved ones.
        var total = records.reduce(0) { $0 + $1.payload.count }
        for approved in [false, true] where total > maxPayloadBytes {
            for index in records.indices.reversed() where total > maxPayloadBytes
                && !records[index].payload.isEmpty && (records[index].outcome == .approved) == approved {
                total -= records[index].payload.count
                records[index].payload = Data()
            }
        }
        if deferWrite {
            schedulePersist()
        } else {
            try persist()
        }
    }

    /// Writes a deferred change now (when the app goes to the background).
    public func flush() throws {
        guard pendingWrite != nil else { return }
        try persist()
    }

    private func schedulePersist() {
        guard fileURL != nil, pendingWrite == nil else { return }
        let delay = writeDelay
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.writePending()
        }
    }

    private func writePending() {
        guard pendingWrite != nil else { return }
        try? persist()
    }

    public func delete(id: UUID) throws {
        records.removeAll { $0.id == id }
        try persist()
    }

    public func clear() throws {
        records.removeAll()
        try persist()
    }

    private func persist() throws {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let fileURL else { return }
        let data = try HistoryStore.encoder.encode(records)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: writeOptions)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
