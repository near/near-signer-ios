import Foundation

// Borsh types mirroring nearcore (core/primitives and core/crypto).
// Every type can be decoded and encoded, so decoding can be verified by re-encoding.

/// Bounds on hostile input, applied while decoding.
enum Limits {
    /// nearcore's `max_actions_per_receipt`.
    static let actions = 100
    /// Function-call access keys: nearcore limits the names to 2,000 bytes in total.
    static let methodNames = 2_000
    static let stateInitEntries = 10_000
}

public enum PublicKey: Equatable, Hashable, Sendable, CustomStringConvertible {
    case ed25519(Data)    // tag 0, 32 bytes
    case secp256k1(Data)  // tag 1, 64 bytes
    case mlDsa65(Data)    // tag 2, 1952 bytes

    static func decode(_ reader: inout BorshReader) throws -> PublicKey {
        let tag = try reader.readU8()
        switch tag {
        case 0: return .ed25519(try reader.readFixed(32))
        case 1: return .secp256k1(try reader.readFixed(64))
        case 2: return .mlDsa65(try reader.readFixed(1952))
        default: throw BorshError.invalidEnumTag(type: "PublicKey", tag: tag)
        }
    }

    func encode(_ writer: inout BorshWriter) {
        switch self {
        case let .ed25519(bytes): writer.writeU8(0); writer.writeFixed(bytes)
        case let .secp256k1(bytes): writer.writeU8(1); writer.writeFixed(bytes)
        case let .mlDsa65(bytes): writer.writeU8(2); writer.writeFixed(bytes)
        }
    }

    /// Parses `ed25519:<base58>` (the only kind this signer uses).
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        // 32 bytes are at most 44 base58 characters; refuse longer input before decoding it.
        guard trimmed.hasPrefix("ed25519:"), trimmed.count <= 8 + 44,
              let bytes = Base58.decode(String(trimmed.dropFirst(8))), bytes.count == 32 else { return nil }
        self = .ed25519(bytes)
    }

    public var description: String {
        switch self {
        case let .ed25519(bytes): return "ed25519:" + Base58.encode(bytes)
        case let .secp256k1(bytes): return "secp256k1:" + Base58.encode(bytes)
        case let .mlDsa65(bytes): return "ml-dsa-65:" + Base58.encode(bytes)
        }
    }
}

public enum Signature: Equatable, Sendable, CustomStringConvertible {
    case ed25519(Data)    // tag 0, 64 bytes
    case secp256k1(Data)  // tag 1, 65 bytes
    case mlDsa65(Data)    // tag 2, 3309 bytes

    static func decode(_ reader: inout BorshReader) throws -> Signature {
        let tag = try reader.readU8()
        switch tag {
        case 0: return .ed25519(try reader.readFixed(64))
        case 1: return .secp256k1(try reader.readFixed(65))
        case 2: return .mlDsa65(try reader.readFixed(3309))
        default: throw BorshError.invalidEnumTag(type: "Signature", tag: tag)
        }
    }

    func encode(_ writer: inout BorshWriter) {
        switch self {
        case let .ed25519(bytes): writer.writeU8(0); writer.writeFixed(bytes)
        case let .secp256k1(bytes): writer.writeU8(1); writer.writeFixed(bytes)
        case let .mlDsa65(bytes): writer.writeU8(2); writer.writeFixed(bytes)
        }
    }

    public var description: String {
        switch self {
        case let .ed25519(bytes): return "ed25519:" + Base58.encode(bytes)
        case let .secp256k1(bytes): return "secp256k1:" + Base58.encode(bytes)
        case let .mlDsa65(bytes): return "ml-dsa-65:" + Base58.encode(bytes)
        }
    }
}

public struct FunctionCallPermission: Equatable, Sendable {
    public var allowance: U128?
    public var receiverId: String
    public var methodNames: [String]

    public init(allowance: U128?, receiverId: String, methodNames: [String]) {
        self.allowance = allowance
        self.receiverId = receiverId
        self.methodNames = methodNames
    }

    static func decode(_ reader: inout BorshReader) throws -> FunctionCallPermission {
        FunctionCallPermission(
            allowance: try reader.readOption { try $0.readU128() },
            receiverId: try reader.readString(),
            methodNames: try reader.readVector(maxCount: Limits.methodNames) { try $0.readString() })
    }

    func encode(_ writer: inout BorshWriter) {
        writer.writeOption(allowance) { $0.writeU128($1) }
        writer.writeString(receiverId)
        writer.writeVector(methodNames) { $0.writeString($1) }
    }
}

public struct GasKeyInfo: Equatable, Sendable {
    public var balance: U128
    public var numNonces: UInt16

    static func decode(_ reader: inout BorshReader) throws -> GasKeyInfo {
        let balance = try reader.readU128()
        let nonces = try reader.readFixed(2)
        return GasKeyInfo(balance: balance, numNonces: UInt16(nonces[0]) | UInt16(nonces[1]) << 8)
    }

    func encode(_ writer: inout BorshWriter) {
        writer.writeU128(balance)
        writer.writeU8(UInt8(numNonces & 0xFF))
        writer.writeU8(UInt8(numNonces >> 8))
    }
}

public enum AccessKeyPermission: Equatable, Sendable {
    case functionCall(FunctionCallPermission)                 // 0
    case fullAccess                                           // 1
    case gasKeyFunctionCall(GasKeyInfo, FunctionCallPermission) // 2
    case gasKeyFullAccess(GasKeyInfo)                         // 3

    static func decode(_ reader: inout BorshReader) throws -> AccessKeyPermission {
        let tag = try reader.readU8()
        switch tag {
        case 0: return .functionCall(try .decode(&reader))
        case 1: return .fullAccess
        case 2: return .gasKeyFunctionCall(try .decode(&reader), try .decode(&reader))
        case 3: return .gasKeyFullAccess(try .decode(&reader))
        default: throw BorshError.invalidEnumTag(type: "AccessKeyPermission", tag: tag)
        }
    }

    func encode(_ writer: inout BorshWriter) {
        switch self {
        case let .functionCall(permission):
            writer.writeU8(0); permission.encode(&writer)
        case .fullAccess:
            writer.writeU8(1)
        case let .gasKeyFunctionCall(info, permission):
            writer.writeU8(2); info.encode(&writer); permission.encode(&writer)
        case let .gasKeyFullAccess(info):
            writer.writeU8(3); info.encode(&writer)
        }
    }

    public var isFullAccess: Bool {
        switch self {
        case .fullAccess, .gasKeyFullAccess: return true
        case .functionCall, .gasKeyFunctionCall: return false
        }
    }
}

public struct AccessKey: Equatable, Sendable {
    public var nonce: UInt64
    public var permission: AccessKeyPermission

    public init(nonce: UInt64, permission: AccessKeyPermission) {
        self.nonce = nonce
        self.permission = permission
    }

    static func decode(_ reader: inout BorshReader) throws -> AccessKey {
        AccessKey(nonce: try reader.readU64(), permission: try .decode(&reader))
    }

    func encode(_ writer: inout BorshWriter) {
        writer.writeU64(nonce)
        permission.encode(&writer)
    }
}

public enum GlobalContractDeployMode: UInt8, Equatable, Sendable {
    case codeHash = 0
    case accountId = 1
}

public enum GlobalContractIdentifier: Equatable, Sendable, CustomStringConvertible {
    case codeHash(Data)     // 0, [u8; 32]
    case accountId(String)  // 1

    static func decode(_ reader: inout BorshReader) throws -> GlobalContractIdentifier {
        let tag = try reader.readU8()
        switch tag {
        case 0: return .codeHash(try reader.readFixed(32))
        case 1: return .accountId(try reader.readString())
        default: throw BorshError.invalidEnumTag(type: "GlobalContractIdentifier", tag: tag)
        }
    }

    func encode(_ writer: inout BorshWriter) {
        switch self {
        case let .codeHash(hash): writer.writeU8(0); writer.writeFixed(hash)
        case let .accountId(account): writer.writeU8(1); writer.writeString(account)
        }
    }

    public var description: String {
        switch self {
        case let .codeHash(hash): return "code hash " + Base58.encode(hash)
        case let .accountId(account): return "account " + account
        }
    }
}

/// `DeterministicAccountStateInit::V1 { code, data: BTreeMap<Vec<u8>, Vec<u8>> }`
public struct DeterministicStateInit: Equatable, Sendable {
    public var code: GlobalContractIdentifier
    public var data: [(key: Data, value: Data)]

    public static func == (lhs: DeterministicStateInit, rhs: DeterministicStateInit) -> Bool {
        lhs.code == rhs.code && lhs.data.map(\.key) == rhs.data.map(\.key)
            && lhs.data.map(\.value) == rhs.data.map(\.value)
    }

    static func decode(_ reader: inout BorshReader) throws -> DeterministicStateInit {
        let version = try reader.readU8()
        guard version == 0 else {
            throw BorshError.invalidEnumTag(type: "DeterministicAccountStateInit", tag: version)
        }
        let code = try GlobalContractIdentifier.decode(&reader)
        let entries = try reader.readVector(maxCount: Limits.stateInitEntries) { reader in
            (key: try reader.readByteVector(), value: try reader.readByteVector())
        }
        return DeterministicStateInit(code: code, data: entries)
    }

    func encode(_ writer: inout BorshWriter) {
        writer.writeU8(0)
        code.encode(&writer)
        writer.writeVector(data) { writer, entry in
            writer.writeByteVector(entry.key)
            writer.writeByteVector(entry.value)
        }
    }
}

/// `TransactionNonce` (TransactionV1 and DelegateActionV2).
public enum TransactionNonce: Equatable, Sendable, CustomStringConvertible {
    case nonce(UInt64)                              // 0
    case gasKeyNonce(nonce: UInt64, index: UInt16)  // 1

    static func decode(_ reader: inout BorshReader) throws -> TransactionNonce {
        let tag = try reader.readU8()
        switch tag {
        case 0:
            return .nonce(try reader.readU64())
        case 1:
            let nonce = try reader.readU64()
            let index = try reader.readFixed(2)
            return .gasKeyNonce(nonce: nonce, index: UInt16(index[0]) | UInt16(index[1]) << 8)
        default:
            throw BorshError.invalidEnumTag(type: "TransactionNonce", tag: tag)
        }
    }

    func encode(_ writer: inout BorshWriter) {
        switch self {
        case let .nonce(nonce):
            writer.writeU8(0); writer.writeU64(nonce)
        case let .gasKeyNonce(nonce, index):
            writer.writeU8(1); writer.writeU64(nonce)
            writer.writeU8(UInt8(index & 0xFF)); writer.writeU8(UInt8(index >> 8))
        }
    }

    public var description: String {
        switch self {
        case let .nonce(nonce): return String(nonce)
        case let .gasKeyNonce(nonce, index): return "\(nonce) (gas key nonce index \(index))"
        }
    }
}

public struct FunctionCallAction: Equatable, Sendable {
    public var methodName: String
    public var args: Data
    public var gas: UInt64
    public var deposit: U128

    public init(methodName: String, args: Data, gas: UInt64, deposit: U128) {
        self.methodName = methodName
        self.args = args
        self.gas = gas
        self.deposit = deposit
    }
}

public indirect enum Action: Equatable, Sendable {
    case createAccount                                                   // 0
    case deployContract(code: Data)                                      // 1
    case functionCall(FunctionCallAction)                                // 2
    case transfer(deposit: U128)                                         // 3
    case stake(stake: U128, publicKey: PublicKey)                        // 4
    case addKey(publicKey: PublicKey, accessKey: AccessKey)              // 5
    case deleteKey(publicKey: PublicKey)                                 // 6
    case deleteAccount(beneficiaryId: String)                            // 7
    case delegate(SignedDelegateAction)                                  // 8
    case deployGlobalContract(code: Data, mode: GlobalContractDeployMode) // 9
    case useGlobalContract(GlobalContractIdentifier)                     // 10
    case deterministicStateInit(DeterministicStateInit, deposit: U128)   // 11
    case transferToGasKey(publicKey: PublicKey, deposit: U128)           // 12
    case withdrawFromGasKey(publicKey: PublicKey, amount: U128)          // 13
    case delegateV2(SignedDelegateActionV2)                              // 14
    case universalStateInit(rawStateInit: Data, deposit: U128)           // 15

    /// - Parameter allowDelegate: false inside a delegate action (`NonDelegateAction`).
    static func decode(_ reader: inout BorshReader, allowDelegate: Bool = true) throws -> Action {
        let tag = try reader.readU8()
        switch tag {
        case 0:
            return .createAccount
        case 1:
            return .deployContract(code: try reader.readByteVector())
        case 2:
            return .functionCall(FunctionCallAction(
                methodName: try reader.readString(),
                args: try reader.readByteVector(),
                gas: try reader.readU64(),
                deposit: try reader.readU128()))
        case 3:
            return .transfer(deposit: try reader.readU128())
        case 4:
            return .stake(stake: try reader.readU128(), publicKey: try .decode(&reader))
        case 5:
            return .addKey(publicKey: try .decode(&reader), accessKey: try .decode(&reader))
        case 6:
            return .deleteKey(publicKey: try .decode(&reader))
        case 7:
            return .deleteAccount(beneficiaryId: try reader.readString())
        case 8 where allowDelegate:
            return .delegate(try .decode(&reader))
        case 9:
            let code = try reader.readByteVector()
            let modeTag = try reader.readU8()
            guard let mode = GlobalContractDeployMode(rawValue: modeTag) else {
                throw BorshError.invalidEnumTag(type: "GlobalContractDeployMode", tag: modeTag)
            }
            return .deployGlobalContract(code: code, mode: mode)
        case 10:
            return .useGlobalContract(try .decode(&reader))
        case 11:
            return .deterministicStateInit(try .decode(&reader), deposit: try reader.readU128())
        case 12:
            return .transferToGasKey(publicKey: try .decode(&reader), deposit: try reader.readU128())
        case 13:
            return .withdrawFromGasKey(publicKey: try .decode(&reader), amount: try reader.readU128())
        case 14 where allowDelegate:
            return .delegateV2(try .decode(&reader))
        case 15:
            return .universalStateInit(rawStateInit: try reader.readByteVector(), deposit: try reader.readU128())
        default:
            throw BorshError.invalidEnumTag(type: allowDelegate ? "Action" : "NonDelegateAction", tag: tag)
        }
    }

    func encode(_ writer: inout BorshWriter) {
        switch self {
        case .createAccount:
            writer.writeU8(0)
        case let .deployContract(code):
            writer.writeU8(1); writer.writeByteVector(code)
        case let .functionCall(call):
            writer.writeU8(2)
            writer.writeString(call.methodName)
            writer.writeByteVector(call.args)
            writer.writeU64(call.gas)
            writer.writeU128(call.deposit)
        case let .transfer(deposit):
            writer.writeU8(3); writer.writeU128(deposit)
        case let .stake(stake, publicKey):
            writer.writeU8(4); writer.writeU128(stake); publicKey.encode(&writer)
        case let .addKey(publicKey, accessKey):
            writer.writeU8(5); publicKey.encode(&writer); accessKey.encode(&writer)
        case let .deleteKey(publicKey):
            writer.writeU8(6); publicKey.encode(&writer)
        case let .deleteAccount(beneficiaryId):
            writer.writeU8(7); writer.writeString(beneficiaryId)
        case let .delegate(signed):
            writer.writeU8(8); signed.encode(&writer)
        case let .deployGlobalContract(code, mode):
            writer.writeU8(9); writer.writeByteVector(code); writer.writeU8(mode.rawValue)
        case let .useGlobalContract(identifier):
            writer.writeU8(10); identifier.encode(&writer)
        case let .deterministicStateInit(stateInit, deposit):
            writer.writeU8(11); stateInit.encode(&writer); writer.writeU128(deposit)
        case let .transferToGasKey(publicKey, deposit):
            writer.writeU8(12); publicKey.encode(&writer); writer.writeU128(deposit)
        case let .withdrawFromGasKey(publicKey, amount):
            writer.writeU8(13); publicKey.encode(&writer); writer.writeU128(amount)
        case let .delegateV2(signed):
            writer.writeU8(14); signed.encode(&writer)
        case let .universalStateInit(raw, deposit):
            writer.writeU8(15); writer.writeByteVector(raw); writer.writeU128(deposit)
        }
    }
}

/// NEP-366 delegate action (meta transaction).
public struct DelegateAction: Equatable, Sendable {
    public var senderId: String
    public var receiverId: String
    public var actions: [Action]
    public var nonce: UInt64
    public var maxBlockHeight: UInt64
    public var publicKey: PublicKey

    public init(senderId: String, receiverId: String, actions: [Action], nonce: UInt64,
                maxBlockHeight: UInt64, publicKey: PublicKey) {
        self.senderId = senderId
        self.receiverId = receiverId
        self.actions = actions
        self.nonce = nonce
        self.maxBlockHeight = maxBlockHeight
        self.publicKey = publicKey
    }

    static func decode(_ reader: inout BorshReader) throws -> DelegateAction {
        DelegateAction(
            senderId: try reader.readString(),
            receiverId: try reader.readString(),
            actions: try reader.readVector(maxCount: Limits.actions) { try Action.decode(&$0, allowDelegate: false) },
            nonce: try reader.readU64(),
            maxBlockHeight: try reader.readU64(),
            publicKey: try .decode(&reader))
    }

    func encode(_ writer: inout BorshWriter) {
        writer.writeString(senderId)
        writer.writeString(receiverId)
        writer.writeVector(actions) { $1.encode(&$0) }
        writer.writeU64(nonce)
        writer.writeU64(maxBlockHeight)
        publicKey.encode(&writer)
    }

    public static func decode(_ data: Data) throws -> DelegateAction {
        var reader = BorshReader(data)
        let action = try decode(&reader)
        try reader.ensureAtEnd()
        return action
    }

    public var borsh: Data {
        var writer = BorshWriter()
        encode(&writer)
        return writer.data
    }
}

public struct SignedDelegateAction: Equatable, Sendable {
    public var delegateAction: DelegateAction
    public var signature: Signature

    static func decode(_ reader: inout BorshReader) throws -> SignedDelegateAction {
        SignedDelegateAction(delegateAction: try .decode(&reader), signature: try .decode(&reader))
    }

    func encode(_ writer: inout BorshWriter) {
        delegateAction.encode(&writer)
        signature.encode(&writer)
    }
}

/// NEP-611 `DelegateActionV2` (wrapped in `VersionedDelegateActionPayload::V2`).
public struct DelegateActionV2: Equatable, Sendable {
    public var senderId: String
    public var receiverId: String
    public var actions: [Action]
    public var nonce: TransactionNonce
    public var maxBlockHeight: UInt64
    public var publicKey: PublicKey

    static func decode(_ reader: inout BorshReader) throws -> DelegateActionV2 {
        DelegateActionV2(
            senderId: try reader.readString(),
            receiverId: try reader.readString(),
            actions: try reader.readVector(maxCount: Limits.actions) { try Action.decode(&$0, allowDelegate: false) },
            nonce: try .decode(&reader),
            maxBlockHeight: try reader.readU64(),
            publicKey: try .decode(&reader))
    }

    func encode(_ writer: inout BorshWriter) {
        writer.writeString(senderId)
        writer.writeString(receiverId)
        writer.writeVector(actions) { $1.encode(&$0) }
        nonce.encode(&writer)
        writer.writeU64(maxBlockHeight)
        publicKey.encode(&writer)
    }
}

public struct SignedDelegateActionV2: Equatable, Sendable {
    public var delegateAction: DelegateActionV2
    public var signature: Signature

    static func decode(_ reader: inout BorshReader) throws -> SignedDelegateActionV2 {
        let version = try reader.readU8()
        guard version == 0 else {
            throw BorshError.invalidEnumTag(type: "VersionedDelegateActionPayload", tag: version)
        }
        return SignedDelegateActionV2(delegateAction: try .decode(&reader), signature: try .decode(&reader))
    }

    func encode(_ writer: inout BorshWriter) {
        writer.writeU8(0)
        delegateAction.encode(&writer)
        signature.encode(&writer)
    }
}

public enum NonceMode: UInt8, Equatable, Sendable {
    case monotonic = 0
    case strict = 1
}

public struct Transaction: Equatable, Sendable {
    public enum Version: Equatable, Sendable {
        case v0
        case v1(nonceMode: NonceMode)
    }

    public var version: Version
    public var signerId: String
    public var publicKey: PublicKey
    public var nonce: TransactionNonce
    public var receiverId: String
    public var blockHash: Data
    public var actions: [Action]

    public init(signerId: String, publicKey: PublicKey, nonce: UInt64, receiverId: String,
                blockHash: Data, actions: [Action]) {
        self.version = .v0
        self.signerId = signerId
        self.publicKey = publicKey
        self.nonce = .nonce(nonce)
        self.receiverId = receiverId
        self.blockHash = blockHash
        self.actions = actions
    }

    public init(version: Version, signerId: String, publicKey: PublicKey, nonce: TransactionNonce,
                receiverId: String, blockHash: Data, actions: [Action]) {
        self.version = version
        self.signerId = signerId
        self.publicKey = publicKey
        self.nonce = nonce
        self.receiverId = receiverId
        self.blockHash = blockHash
        self.actions = actions
    }

    /// Decodes `borsh(Transaction)`. V0 has no tag. V1 starts with byte 1 followed by the
    /// signer id length, whose low byte is never 0, while V0 starts with `len, 0, 0, 0`.
    public static func decode(_ data: Data) throws -> Transaction {
        var reader = BorshReader(data)
        let bytes = [UInt8](data.prefix(2))
        let isV1 = bytes.count == 2 && bytes[0] == 1 && bytes[1] != 0
        if isV1 { _ = try reader.readU8() }

        let signerId = try reader.readString()
        let publicKey = try PublicKey.decode(&reader)
        let nonce: TransactionNonce = isV1 ? try .decode(&reader) : .nonce(try reader.readU64())
        let receiverId = try reader.readString()
        let blockHash = try reader.readFixed(32)
        let actions = try reader.readVector(maxCount: Limits.actions) { try Action.decode(&$0) }
        var version = Version.v0
        if isV1 {
            let modeTag = try reader.readU8()
            guard let mode = NonceMode(rawValue: modeTag) else {
                throw BorshError.invalidEnumTag(type: "NonceMode", tag: modeTag)
            }
            version = .v1(nonceMode: mode)
        }
        try reader.ensureAtEnd()
        return Transaction(version: version, signerId: signerId, publicKey: publicKey, nonce: nonce,
                           receiverId: receiverId, blockHash: blockHash, actions: actions)
    }

    public var borsh: Data {
        var writer = BorshWriter()
        switch version {
        case .v0:
            writer.writeString(signerId)
            publicKey.encode(&writer)
            if case let .nonce(value) = nonce {
                writer.writeU64(value)
            } else {
                preconditionFailure("TransactionV0 supports plain nonces only")
            }
            writer.writeString(receiverId)
            writer.writeFixed(blockHash)
            writer.writeVector(actions) { $1.encode(&$0) }
        case let .v1(nonceMode):
            writer.writeU8(1)
            writer.writeString(signerId)
            publicKey.encode(&writer)
            nonce.encode(&writer)
            writer.writeString(receiverId)
            writer.writeFixed(blockHash)
            writer.writeVector(actions) { $1.encode(&$0) }
            writer.writeU8(nonceMode.rawValue)
        }
        return writer.data
    }
}

/// NEP-413 off-chain message payload.
public struct NEP413Payload: Equatable, Sendable {
    public var message: String
    public var nonce: Data
    public var recipient: String
    public var callbackUrl: String?

    public init(message: String, nonce: Data, recipient: String, callbackUrl: String?) {
        self.message = message
        self.nonce = nonce
        self.recipient = recipient
        self.callbackUrl = callbackUrl
    }

    public static func decode(_ data: Data) throws -> NEP413Payload {
        var reader = BorshReader(data)
        let payload = NEP413Payload(
            message: try reader.readString(),
            nonce: try reader.readFixed(32),
            recipient: try reader.readString(),
            callbackUrl: try reader.readOption { try $0.readString() })
        try reader.ensureAtEnd()
        return payload
    }

    public var borsh: Data {
        var writer = BorshWriter()
        writer.writeString(message)
        writer.writeFixed(nonce)
        writer.writeString(recipient)
        writer.writeOption(callbackUrl) { $0.writeString($1) }
        return writer.data
    }
}

/// What gets hashed and signed for each request kind.
public enum SigningDigest {
    /// 2^30 + 366, NEP-366 on-chain signable message discriminant.
    public static let nep366Discriminant: UInt32 = (1 << 30) + 366
    /// 2^31 + 413, NEP-413 off-chain signable message discriminant.
    public static let nep413Discriminant: UInt32 = (1 << 31) + 413

    /// NEAR signs `sha256(borsh(Transaction))`; the hash is also the transaction id.
    public static func transaction(_ borsh: Data) -> Data {
        Data(SHA256.hash(data: borsh))
    }

    public static func delegateAction(_ borsh: Data) -> Data {
        prefixed(nep366Discriminant, borsh)
    }

    public static func nep413(_ borsh: Data) -> Data {
        prefixed(nep413Discriminant, borsh)
    }

    private static func prefixed(_ discriminant: UInt32, _ borsh: Data) -> Data {
        var writer = BorshWriter()
        writer.writeU32(discriminant)
        writer.writeFixed(borsh)
        return Data(SHA256.hash(data: writer.data))
    }
}

public extension Transaction {
    /// `borsh(SignedTransaction)` for an ed25519 signature, ready for `send_tx` / near-cli-rs.
    static func signedTransaction(unsignedBorsh: Data, ed25519Signature: Data) -> Data {
        var writer = BorshWriter()
        writer.writeFixed(unsignedBorsh)
        Signature.ed25519(ed25519Signature).encode(&writer)
        return writer.data
    }
}
