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

    private var session: Session?
    private var known: [Data?] = []
    private var knownCount = 0
    private var mixed: [Mixed] = []
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
        finished = false
        updateProgress()
    }

    private func absorb(_ frame: OpticalFrame) -> Outcome {
        guard let session else { return .notAFrame }
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
            // Bounded: a hostile or very long stream can't grow memory without end.
            let cap = max(16, min(4 * session.count, 4096))
            if mixed.count >= cap { mixed.removeFirst() }
            mixed.append(Mixed(unknown: unknown, data: data))
        }
        updateProgress()
        guard knownCount == session.count else { return .progress(progress!) }
        finished = true
        mixed = []
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
                if entry.unknown.count == 1 {
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
