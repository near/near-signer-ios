import Foundation

public struct OpticalProgress: Equatable, Sendable {
    /// Fragments recovered.
    public var known: Int
    /// K, the fragments the message takes.
    public var total: Int
    /// Message bytes.
    public var length: Int
    public var sessionId: UInt32

    public init(known: Int, total: Int, length: Int, sessionId: UInt32) {
        self.known = known
        self.total = total
        self.length = length
        self.sessionId = sessionId
    }
}

/// The phone's side: fed the text of every QR code the camera sees, it recovers the message by
/// peeling (a mixed frame whose other fragments are known yields the missing one, which may in
/// turn resolve earlier mixed frames). Not thread-safe; the owner serializes calls. After
/// `.complete`, `progress` and `sessionId` stay until `reset()`, so the owner can read the
/// session id for the response, and more frames of that session are duplicates.
public final class OpticalReceiver {
    public enum Outcome: Equatable {
        /// Not an `NS1:` frame: another QR code in view. Ignore silently.
        case notAFrame
        /// The frame carried nothing new.
        case duplicate
        /// A frame of another transfer, ignored. Three in a row from one new session start over
        /// with it (reported as `.progress`).
        case otherSession
        case progress(OpticalProgress)
        /// The message, checksum verified, padding removed.
        case complete(Data)
        /// Checksum mismatch, or frames of one session disagreeing about the message: the
        /// receiver starts over. The text is for the user.
        case invalid(String)
    }

    private struct Session {
        let id: UInt32
        let length: Int
        let fragmentSize: Int
        let crc: UInt32
        let count: Int
    }

    private struct Mixed {
        var unknown: Set<Int>
        var data: Data
    }

    /// Unknown fragment indexes the kept mixed frames may hold in all, per fragment of the message.
    /// Each costs a set entry, so without a budget a hostile screen could declare 65 535 one-byte
    /// fragments and show frames mixing tens of thousands of them: gigabytes across the kept
    /// frames. An honest transfer stays far below it (frames mix about ln K fragments on average).
    static let heldIndexesPerFragment = 16

    /// A mixed frame of more fragments than this is skipped before they are chosen. Choosing them
    /// costs a dictionary and a set that size, on the main actor, every time the camera reads the
    /// code: a hostile screen holding still a few codes that mix tens of thousands of 1-byte
    /// fragments would freeze the app. Under the ideal soliton about 0.1% of mixed frames mix
    /// more, and they almost never peel.
    static let maxMixedDegree = 1024

    private var session: Session?
    private var known: [Data?] = []
    private var knownCount = 0
    private var mixed: [Mixed] = []
    /// Unknown fragment indexes held across `mixed`.
    private(set) var heldIndexes = 0
    private var finished = false
    private var otherSessionId: UInt32?
    private var otherSessionFrames = 0

    public init() {}

    public private(set) var progress: OpticalProgress?

    public var sessionId: UInt32? { session?.id }

    public func reset() {
        session = nil
        known = []
        knownCount = 0
        mixed = []
        heldIndexes = 0
        finished = false
        progress = nil
        otherSessionId = nil
        otherSessionFrames = 0
    }

    public func receive(_ text: String) -> Outcome {
        guard let frame = OpticalFrame(text: text) else { return .notAFrame }
        if let session {
            if frame.sessionId != session.id {
                if otherSessionId == frame.sessionId {
                    otherSessionFrames += 1
                } else {
                    otherSessionId = frame.sessionId
                    otherSessionFrames = 1
                }
                guard otherSessionFrames >= 3 else { return .otherSession }
                reset()
                start(frame)
            } else {
                otherSessionId = nil
                otherSessionFrames = 0
                guard frame.length == session.length, frame.fragmentSize == session.fragmentSize, frame.crc == session.crc else {
                    reset()
                    return .invalid("The codes disagree about the request (its size or checksum). Scanning starts over.")
                }
                if finished { return .duplicate }
            }
        } else {
            start(frame)
        }
        return absorb(frame)
    }

    private func start(_ frame: OpticalFrame) {
        let count = frame.fragmentCount
        session = Session(id: frame.sessionId, length: frame.length, fragmentSize: frame.fragmentSize, crc: frame.crc, count: count)
        known = Array(repeating: nil, count: count)
        knownCount = 0
        mixed = []
        heldIndexes = 0
        finished = false
        updateProgress()
    }

    private func absorb(_ frame: OpticalFrame) -> Outcome {
        guard let session else { return .notAFrame }
        let degree = Fountain.degree(sessionId: session.id, sequence: frame.sequence, fragmentCount: session.count)
        guard degree <= Self.maxMixedDegree else { return .duplicate }
        let indexes = Fountain.indexes(sessionId: session.id, sequence: frame.sequence, fragmentCount: session.count)
        var data = frame.data
        var unknown = Set<Int>()
        for index in indexes {
            if let fragment = known[index] {
                data.xor(fragment)
            } else {
                unknown.insert(index)
            }
        }
        switch unknown.count {
        case 0:
            return .duplicate
        case 1:
            learn(unknown.first!, data)
        default:
            guard !mixed.contains(where: { $0.unknown == unknown }) else { return .duplicate }
            // Bounded: a hostile or very long stream can't grow memory without end. The oldest
            // frames go first, to keep at most 4096 frames and the budget of unknown indexes.
            let cap = max(16, min(4 * session.count, 4096))
            let budget = Self.heldIndexesPerFragment * session.count
            while !mixed.isEmpty, mixed.count >= cap || heldIndexes + unknown.count > budget {
                heldIndexes -= mixed.removeFirst().unknown.count
            }
            mixed.append(Mixed(unknown: unknown, data: data))
            heldIndexes += unknown.count
        }
        updateProgress()
        guard knownCount == session.count else { return .progress(progress!) }
        finished = true
        mixed = []
        heldIndexes = 0
        var message = Data(capacity: session.count * session.fragmentSize)
        for fragment in known { message.append(fragment!) }
        message = message.prefix(session.length)
        guard CRC32.checksum(message) == session.crc else {
            reset()
            return .invalid("The request's checksum doesn't match. Scanning starts over.")
        }
        return .complete(message)
    }

    /// Records a recovered fragment and peels every mixed frame it completes, in cascade.
    private func learn(_ index: Int, _ data: Data) {
        var queue = [index]
        known[index] = data
        knownCount += 1
        while let solved = queue.popLast() {
            var remaining: [Mixed] = []
            remaining.reserveCapacity(mixed.count)
            for var entry in mixed {
                guard entry.unknown.contains(solved) else {
                    remaining.append(entry)
                    continue
                }
                entry.data.xor(known[solved]!)
                entry.unknown.remove(solved)
                heldIndexes -= 1
                if entry.unknown.count == 1 {
                    heldIndexes -= 1
                    let next = entry.unknown.first!
                    if known[next] == nil {
                        known[next] = entry.data
                        knownCount += 1
                        queue.append(next)
                    }
                } else if entry.unknown.count > 1 {
                    remaining.append(entry)
                }
            }
            mixed = remaining
        }
    }

    private func updateProgress() {
        guard let session else { return }
        progress = OpticalProgress(known: knownCount, total: session.count, length: session.length, sessionId: session.id)
    }
}
