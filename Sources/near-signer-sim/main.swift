// near-signer-sim: runs the exact signing core of the iOS app on macOS/Linux and serves it over
// TCP with Speculos framing (the same protocol the app's iOS Simulator test bridge serves).
// Use it to test host integrations without a phone.

import Foundation
import NearSignerCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var host = "127.0.0.1"
    var port: UInt16 = 9999
    var seedPhrase: String?
    var secretKey: String?
    var decision: Bool? // nil = ask on the terminal
    var historyPath: String?
    var blePackets = false
    var fastMode = true
    var command = "serve"
}

let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

func usage() -> Never {
    print("""
        usage: near-signer-sim [serve] [options]
               near-signer-sim history --history FILE
               near-signer-sim pubkey [--path m/44'/397'/0'/0'/1'] [key options]

        options:
          --host ADDR           listen address (default 127.0.0.1)
          --port N              listen port (default 9999, the Speculos APDU port)
          --seed-phrase "..."   BIP-39 phrase (default: the public BIP-39 test phrase, NEVER use with real funds)
          --secret-key ed25519:...  single NEAR secret key instead of a phrase
          --auto-approve        approve every request (for automated tests)
          --auto-reject         reject every request
          --history FILE        persist signing history as JSON
          --ble-packets         carry raw Ledger BLE packets instead of APDUs: each TCP frame is
                                `u16 BE length | GATT write or notification`. Tests BLE hosts
                                (near-connect's Ledger executor, near-ledger-rs) without radio.
          --no-fast-mode        answer the fast-mode capability command like a Ledger (6D00),
                                to test that hosts fall back to standard 250-byte chunks.
        """)
    exit(2)
}

func parseOptions() -> (Options, BIP32Path) {
    var options = Options()
    var path = BIP32Path.ledgerDefault
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("-") {
        options.command = first
        args.removeFirst()
    }
    var index = 0
    func value() -> String {
        index += 1
        guard index < args.count else { usage() }
        return args[index]
    }
    while index < args.count {
        switch args[index] {
        case "--host": options.host = value()
        case "--port": options.port = UInt16(value()) ?? { usage() }()
        case "--seed-phrase": options.seedPhrase = value()
        case "--secret-key": options.secretKey = value()
        case "--auto-approve": options.decision = true
        case "--auto-reject": options.decision = false
        case "--history": options.historyPath = value()
        case "--ble-packets": options.blePackets = true
        case "--no-fast-mode": options.fastMode = false
        case "--path": path = BIP32Path(value()) ?? { usage() }()
        case "-h", "--help": usage()
        default: print("unknown option \(args[index])"); usage()
        }
        index += 1
    }
    return (options, path)
}

func loadKey(_ options: Options) -> KeyMaterial {
    do {
        if let secretKey = options.secretKey { return try KeyMaterial.fromNearSecretKey(secretKey) }
        if let seedPhrase = options.seedPhrase { return try KeyMaterial.fromMnemonic(seedPhrase) }
        print("WARNING: using the public BIP-39 test phrase. Never send real funds to this key.")
        return try KeyMaterial.fromMnemonic(testMnemonic)
    } catch {
        print("invalid key: \(error)")
        exit(1)
    }
}

/// Approves on the terminal (or automatically). Requests are serialized by the signer service.
struct TerminalPresenter: ApprovalPresenter {
    let decision: Bool?

    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        print("\n================ \(request.transport) request ================")
        print("path: \(request.path)")
        print(request.display.text)
        print("==========================================================")
        if let decision {
            print(decision ? "auto-approved" : "auto-rejected")
            return decision
        }
        print("Approve? [y/N] ", terminator: "")
        fflush(stdout)
        let answer = await Task.detached { readLine() }.value
        return answer?.lowercased().hasPrefix("y") == true
    }
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Runs an async operation from a blocking socket thread.
func blocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var buffer = [UInt8](repeating: 0, count: count)
    var received = 0
    while received < count {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + received, count - received) }
        if n <= 0 { return nil }
        received += n
    }
    return Data(buffer)
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    let bytes = [UInt8](data)
    var sent = 0
    while sent < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
        if n <= 0 { return false }
        sent += n
    }
    return true
}

func serveConnection(_ fd: Int32, service: SignerService, peer: String) {
    let session = NearAppSession(service: service, transport: "TCP \(peer)", offersFastMode: options.fastMode)
    print("host connected: \(peer)")
    while true {
        guard let header = readExactly(fd, 4) else { break }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= TCPFrameDecoder.maxMessageLength, let apdu = readExactly(fd, length) else { break }
        let response = blocking { await session.handle(apdu) }
        print("apdu \(apdu.prefix(5).hexString)… (\(apdu.count) bytes) -> sw \(response.suffix(2).hexString)")
        guard writeAll(fd, TCPFrameDecoder.encodeResponse(response)) else { break }
    }
    close(fd)
    print("host disconnected: \(peer)")
}

/// BLE-packet mode: same code path as the iOS peripheral (BLELink), with TCP instead of radio.
func serveBLEPackets(_ fd: Int32, service: SignerService, peer: String) {
    let session = NearAppSession(service: service, transport: "BLE-over-TCP \(peer)", offersFastMode: options.fastMode)
    let link = BLELink(session: session, packetSize: 156)
    print("BLE host connected: \(peer)")
    while true {
        guard let header = readExactly(fd, 2) else { break }
        let length = Int(header[0]) << 8 | Int(header[1])
        guard let packet = readExactly(fd, length) else { break }
        let notifications = blocking { await link.receive(packet) }
        var ok = true
        for notification in notifications {
            let frame = Data([UInt8(notification.count >> 8), UInt8(notification.count & 0xFF)]) + notification
            if !writeAll(fd, frame) { ok = false; break }
        }
        if !ok { break }
    }
    close(fd)
    print("BLE host disconnected: \(peer)")
}

func serve(_ options: Options, service: SignerService) -> Never {
    #if canImport(Glibc)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { perror("socket"); exit(1) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = options.port.bigEndian
    guard inet_pton(AF_INET, options.host, &address.sin_addr) == 1 else { print("bad --host"); exit(1) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { perror("bind"); exit(1) }
    guard listen(fd, 4) == 0 else { perror("listen"); exit(1) }
    print("near-signer-sim listening on \(options.host):\(options.port) (\(options.blePackets ? "BLE packets over TCP" : "Speculos APDU framing"))")
    while true {
        var peerAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &peerAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
        }
        guard client >= 0 else { continue }
        let peer = "\(String(cString: inet_ntoa(peerAddress.sin_addr))):\(UInt16(bigEndian: peerAddress.sin_port))"
        let blePackets = options.blePackets
        Thread.detachNewThread {
            if blePackets {
                serveBLEPackets(client, service: service, peer: peer)
            } else {
                serveConnection(client, service: service, peer: peer)
            }
        }
    }
}

let (options, path) = parseOptions()
let historyURL = options.historyPath.map { URL(fileURLWithPath: $0) }
let history = HistoryStore(fileURL: historyURL)

switch options.command {
case "history":
    let records = blocking { await history.all() }
    if records.isEmpty { print("no history") }
    let formatter = ISO8601DateFormatter()
    for record in records {
        print("\(formatter.string(from: record.date))  \(record.outcome.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(record.title)")
        if let hash = record.hash { print("    hash \(hash)") }
        if let reason = record.failureReason { print("    reason: \(reason)") }
    }
case "pubkey":
    let key = loadKey(options)
    do {
        print(try key.privateKey(for: path).publicKey.nearString)
    } catch {
        print("error: \(error)")
        exit(1)
    }
case "serve":
    let material = loadKey(options)
    let vault = InMemoryKeyVault(material: material)
    let service = SignerService(vault: vault, presenter: TerminalPresenter(decision: options.decision), history: history)
    if let key = try? material.privateKey(for: .ledgerDefault) {
        print("public key at \(BIP32Path.ledgerDefault): \(key.publicKey.nearString)")
    }
    // Automatic refusals reach the history file in batches: write them before exiting.
    var stopSignals: [DispatchSourceSignal] = []
    for signo in [SIGTERM, SIGINT] {
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
        source.setEventHandler {
            blocking { try? await history.flush() }
            exit(0)
        }
        source.resume()
        stopSignals.append(source)
    }
    serve(options, service: service)
default:
    usage()
}
