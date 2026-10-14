import Foundation
import NearSignerCore

/// The wallet list (public data: names, accounts, public keys), shared by the key vault, which
/// runs on the signer's thread, and the UI. Every change is saved before it takes effect, and
/// reported to `onChange`.
final class WalletRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var list = WalletList()
    var onChange: (@Sendable (WalletList) -> Void)?

    init(url: URL) {
        self.url = url
    }

    var snapshot: WalletList { lock.withLock { list } }

    /// Reads the file. It has complete data protection, so this must wait until the phone is
    /// unlocked. A damaged file is kept aside (never overwritten), and the vault then recovers the
    /// wallets from the keychain.
    func load() {
        let loaded: WalletList
        switch WalletList.load(from: url) {
        case .missing:
            loaded = WalletList()
        case let .loaded(list):
            loaded = list
        case .unreadable:
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            loaded = WalletList()
        }
        lock.withLock { list = loaded }
        onChange?(loaded)
    }

    /// Applies `change`, saves, and only then publishes. If saving fails, nothing changes.
    @discardableResult
    func update<Result>(_ change: (inout WalletList) throws -> Result) throws -> Result {
        let (result, updated, changed): (Result, WalletList, Bool) = try lock.withLock {
            var copy = list
            let result = try change(&copy)
            guard copy != list else { return (result, copy, false) }
            try save(copy)
            list = copy
            return (result, copy, true)
        }
        if changed { onChange?(updated) }
        return result
    }

    private func save(_ list: WalletList) throws {
        try list.save(to: url, options: [.atomic, .completeFileProtection])
        // The keys are this-device-only, so a backup of the list would restore wallets that
        // cannot sign.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var fileURL = url
        try? fileURL.setResourceValues(values)
    }
}
