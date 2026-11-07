import Foundation
import NearSignerCore
import Network
import Observation
import UIKit

/// Bridges the signer core (which runs off the main thread) to the SwiftUI approval screen.
final class ApprovalCoordinator: ApprovalPresenter, @unchecked Sendable {
    weak var model: AppModel?

    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    guard let model = self.model else {
                        continuation.resume(returning: false)
                        return
                    }
                    model.present(request, continuation: continuation)
                }
            }
        } onCancel: {
            // The host disconnected or the app went to the background.
            Task { @MainActor in self.model?.cancel(id) }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // Wallets and accounts (mirror of the registry)
    private(set) var wallets = WalletList()

    // Approval
    var pendingRequest: ApprovalRequest?
    /// A large request that is still arriving (shown with progress and a Cancel button).
    private(set) var receiving: ReceiveProgress?
    private(set) var isCancellingReceive = false
    @ObservationIgnored private var lastReceiveUpdate = Date()
    @ObservationIgnored private var receiveWatchdog: Task<Void, Never>?
    private(set) var lastResult: HistoryRecord?

    // History
    private(set) var history: [HistoryRecord] = []

    // Connection and environment
    private(set) var bleStatus: BLEStatus = .off
    private(set) var bridgeStatus: BridgeStatus = .off
    private(set) var networkAvailable = false
    /// False until SwiftUI reports the scene active, so the privacy shield covers the launch and
    /// the lock screen sees the change to active.
    private(set) var isSceneActive = false
    var errorMessage: String?

    // Camera transfer (README "Camera transfer"): a request scanned from a computer's screen.
    enum CameraTransfer: Equatable {
        /// The scan screen is open; progress once the first frame of a request was seen.
        case scanning(OpticalProgress?)
        /// The request is with the signer: the approval screen is up, or the key is being unlocked.
        case processing
        /// The answer, shown as one QR code until Done.
        case response(OpticalResponse)
    }

    private(set) var cameraTransfer: CameraTransfer?
    /// Bytes per second of the transfer in progress, once it can be told.
    private(set) var cameraSpeed: Double?
    let cameraScanner = CameraScanner()
    @ObservationIgnored private let cameraReceiver = OpticalReceiver()
    @ObservationIgnored private var cameraStartedAt: Date?
    /// The scanned request on its way through the signer; cancelled when the app leaves the
    /// foreground, which rejects its approval even before it is shown.
    @ObservationIgnored private var cameraTask: Task<Void, Never>?

    // Settings (persisted)
    private(set) var appearance: AppAppearance
    private(set) var bluetoothEnabled: Bool
    private(set) var requirePairing: Bool
    private(set) var autoSharePublicKeys: Bool
    /// Ask for Face ID or the passcode each time the app is opened (on by default).
    private(set) var appLockEnabled: Bool

    // App lock
    /// Unlocked for this visit; the app locks again when it goes to the background.
    private(set) var isUnlocked = false
    private(set) var isUnlocking = false
    /// Unlocked while Face ID or the passcode prompt was still closing (the app is inactive until
    /// it has): the privacy shield stays off, so the lock screen gives way straight to the app.
    private var unlockedWhileInactive = false
    private(set) var unlockError: String?
    /// The lock screen asks for Face ID by itself once per visit; after a cancel, the button does.
    @ObservationIgnored private var autoUnlockPending = true
    /// The app was last unlocked with the passcode alone, so the lock screen asks for it again
    /// instead of Face ID.
    private(set) var unlocksWithPasscode: Bool
    /// The first wallet was just added: the home screen shows how to connect a computer.
    var showConnectIntro = false

    let registry: WalletRegistry
    let vault: SecureKeyVault
    let historyStore: HistoryStore
    @ObservationIgnored private let legacyAccountsURL: URL
    /// False until the wallet list could be read (see `loadIfPossible`).
    private(set) var isLoaded = false
    /// Wallets left in the keychain by an earlier installation, waiting for the user's decision.
    private(set) var earlierWallets: [SecureKeyVault.EarlierWallet] = []
    private(set) var strictBiometrics = false
    /// Strict Face ID was turned on in an earlier version; its keys still need re-encrypting.
    private(set) var strictUpgradePending = false
    @ObservationIgnored private var protectedDataObserver: NSObjectProtocol?
    @ObservationIgnored private var service: SignerService!
    @ObservationIgnored private let coordinator = ApprovalCoordinator()
    @ObservationIgnored private var transports: Transports!
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var cancelledRequests: Set<UUID> = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Approval prompts expire after this long (near-ledger-rs gives up after 5 minutes).
    static let approvalTimeout: Duration = .seconds(240)

    init() {
        defaults.register(defaults: [
            "appearance": AppAppearance.system.rawValue,
            "bluetoothEnabled": true,
            "requirePairing": true,
            "autoSharePublicKeys": true,
            "appLock": true,
        ])
        // Read again in `loadIfPossible`: before the first unlock after a reboot, UserDefaults
        // read as empty and these would be the defaults.
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        bluetoothEnabled = defaults.bool(forKey: "bluetoothEnabled")
        requirePairing = defaults.bool(forKey: "requirePairing")
        autoSharePublicKeys = defaults.bool(forKey: "autoSharePublicKeys")
        appLockEnabled = defaults.bool(forKey: "appLock")
        unlocksWithPasscode = defaults.bool(forKey: "unlockWithPasscode")

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        historyStore = HistoryStore(fileURL: directory.appendingPathComponent("signing-history.json"),
                                    writeOptions: [.atomic, .completeFileProtection], excludedFromBackup: true)
        legacyAccountsURL = directory.appendingPathComponent("accounts.json")
        let registry = WalletRegistry(url: directory.appendingPathComponent("wallets.json"))
        self.registry = registry
        vault = SecureKeyVault(registry: registry)

        coordinator.model = self
        registry.onChange = { [weak self] list in
            Task { @MainActor in self?.walletsChanged(list) }
        }
        service = SignerService(vault: vault, presenter: coordinator, history: historyStore) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let service = self.service!
        let autoShare = autoSharePublicKeys
        Task { await service.setAutoShareKnownPublicKeys(autoShare) }
        transports = Transports(
            makeSession: { transport in NearAppSession(service: service, transport: transport) },
            onBLEStatus: { [weak self] status in Task { @MainActor in self?.bleStatus = status } },
            onBridgeStatus: { [weak self] status in Task { @MainActor in self?.bridgeStatus = status } })

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkAvailable = available }
        }
        pathMonitor.start(queue: DispatchQueue(label: "near-signer.network"))

        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadIfPossible() }
        }
    }

    /// Wallets and history are files with complete data protection, unreadable until the phone is
    /// unlocked. iOS can launch the app earlier (prewarming), so loading waits for that; acting
    /// on an empty list would show onboarding, or overwrite the history.
    func loadIfPossible() {
        guard !isLoaded, UIApplication.shared.isProtectedDataAvailable else { return }
        isLoaded = true
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        bluetoothEnabled = defaults.bool(forKey: "bluetoothEnabled")
        requirePairing = defaults.bool(forKey: "requirePairing")
        autoSharePublicKeys = defaults.bool(forKey: "autoSharePublicKeys")
        appLockEnabled = defaults.bool(forKey: "appLock")
        unlocksWithPasscode = defaults.bool(forKey: "unlockWithPasscode")
        appearance.apply()
        let autoShare = autoSharePublicKeys
        let signer = service!
        Task { await signer.setAutoShareKnownPublicKeys(autoShare) }
        registry.load()
        earlierWallets = vault.migrateAndCleanUp(legacyAccountsURL: legacyAccountsURL)
        strictBiometrics = vault.strictBiometrics
        strictUpgradePending = vault.strictUpgradePending
        wallets = registry.snapshot
        let store = historyStore
        Task {
            await store.reload()
            await reloadHistory()
        }
        startTransports()
    }

    private func walletsChanged(_ list: WalletList) {
        let hadKey = hasKey
        wallets = list
        // Read from the keychain: restored wallets keep their own Strict Face ID setting.
        strictBiometrics = vault.strictBiometrics
        // The key behind a path may now be different: forget remembered key mismatches.
        let signer = service!
        Task { await signer.clearKnownMismatches() }
        if hadKey != hasKey {
            if hasKey {
                startTransports()
            } else {
                transports.stop()
                lastResult = nil
            }
        }
    }

    // MARK: Lifecycle

    /// Transports run only while the app is in the foreground and a key exists.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            loadIfPossible()
            startTransports()
        } else {
            transports.stop()
            endReceiving()
            if let pending = pendingRequest { resolve(pending.id, approved: false) }
            // The camera stops too. A scanned request with the signer is cancelled, so it is
            // rejected even if it is still being decoded, and its outcome closes the transfer. An
            // answer on screen stays, behind the lock screen.
            cameraTask?.cancel()
            if case .scanning = cameraTransfer { cancelCameraTransfer() }
            lock()
        }
    }

    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active { unlockedWhileInactive = false }
        if !active {
            // Automatic refusals are written in batches; write them before iOS may suspend the app.
            let store = historyStore
            Task { try? await store.flush() }
        }
    }

    /// Covers the app while it's inactive (the app switcher, the Face ID prompt). The lock screen
    /// covers it already.
    var showsPrivacyShield: Bool { !isSceneActive && !isLocked && !unlockedWhileInactive }

    /// Whether the overlay window has something to show.
    var needsOverlay: Bool {
        pendingRequest != nil || receiving != nil || errorMessage != nil || showsPrivacyShield || isLocked
    }

    private func startTransports() {
        // Computers can't reach a locked app: Bluetooth starts only after unlocking.
        guard isActive, hasKey, isLoaded, !isLocked else {
            transports.stop()
            return
        }
        beginStartingGrace()
        transports.start(bluetooth: bluetoothEnabled, requirePairing: requirePairing)
    }

    /// Bluetooth takes a moment to start after launch or unlocking. For the first two seconds the
    /// link reads as ready, as it almost always is by then, instead of a "Starting…" that flashes
    /// by and changes the card's size. Starting takes longer only when something is wrong.
    private var inStartingGrace = false
    private var startingGraceTask: Task<Void, Never>?

    private func beginStartingGrace() {
        inStartingGrace = true
        startingGraceTask?.cancel()
        startingGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.inStartingGrace = false
        }
    }

    /// What the home screen shows about the link to computers.
    var connection: ConnectionState {
        let state = transportState
        if state == .starting, inStartingGrace {
            #if targetEnvironment(simulator)
            return .simulator(connected: 0)
            #else
            return .waiting
            #endif
        }
        return state
    }

    private var transportState: ConnectionState {
        #if targetEnvironment(simulator)
        switch bridgeStatus {
        case .off: return .starting
        case let .listening(connections): return .simulator(connected: connections)
        case let .failed(message): return .failed(message)
        }
        #else
        guard bluetoothEnabled else { return .disabled }
        switch bleStatus {
        case .off, .starting: return .starting
        case .unauthorized: return .needsPermission
        case .unsupported: return .unsupported
        case .poweredOff: return .bluetoothOff
        case let .advertising(connected): return connected == 0 ? .waiting : .connected(connected)
        case let .failed(message): return .failed(message)
        }
        #endif
    }

    // MARK: App lock

    /// The lock screen covers everything (sheets included) until Face ID or the passcode. There is
    /// nothing to protect before the first wallet exists.
    var isLocked: Bool { appLockEnabled && isLoaded && hasKey && !isUnlocked }

    private func lock() {
        isUnlocked = false
        unlockedWhileInactive = false
        unlockError = nil
        autoUnlockPending = true
        // A focused text field under the lock screen would bring its keyboard back over it.
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.endEditing(true) }
        }
    }

    /// Called while the lock screen is shown and the app is active. Asks once per visit, so that
    /// cancelling Face ID (which briefly makes the app inactive) doesn't ask again in a loop.
    func unlockAutomatically() async {
        guard isLocked, isSceneActive, autoUnlockPending, UIApplication.shared.applicationState == .active else { return }
        autoUnlockPending = false
        await unlock()
    }

    /// Face ID (with the passcode after a failed match), or with `withPasscode` the passcode
    /// alone. Without an argument it uses whichever opened the app last time. Strict Face ID does
    /// not apply here: the passcode must always open the app, so wallets whose strict keys stopped
    /// working can be removed and restored. Signing still asks again, under Strict Face ID with
    /// Face ID only.
    func unlock(withPasscode: Bool? = nil) async {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        let passcode = SecureKeyVault.hasBiometrics ? withPasscode ?? unlocksWithPasscode : false
        do {
            if passcode {
                try await vault.authenticateWithPasscode(reason: "Unlock NEAR Signer")
            } else {
                try await vault.authenticate(reason: "Unlock NEAR Signer")
            }
            if SecureKeyVault.hasBiometrics, passcode != unlocksWithPasscode {
                unlocksWithPasscode = passcode
                defaults.set(passcode, forKey: "unlockWithPasscode")
            }
            unlockError = nil
            finishUnlock()
        } catch KeyError.authenticationCancelled {
            // Stays locked; the Unlock button asks again.
        } catch VaultError.noPasscode {
            #if targetEnvironment(simulator)
            // The Simulator has no passcode, and Face ID only if enrolled in its Features menu.
            finishUnlock()
            #else
            unlockError = VaultError.noPasscode.errorDescription
            #endif
        } catch {
            unlockError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func finishUnlock() {
        unlockedWhileInactive = !isSceneActive
        isUnlocked = true
        startTransports()
    }

    func setAppLock(_ enabled: Bool) async {
        if !enabled {
            guard await confirmIdentity("Turn off the app lock", weakensSecurity: true) else { return }
        }
        appLockEnabled = enabled
        defaults.set(enabled, forKey: "appLock")
        // Turning it on doesn't lock the app the user is looking at.
        if enabled { isUnlocked = true }
    }

    // MARK: Settings

    func setAppearance(_ value: AppAppearance) {
        appearance = value
        defaults.set(value.rawValue, forKey: "appearance")
        value.apply()
    }

    func setBluetoothEnabled(_ enabled: Bool) {
        bluetoothEnabled = enabled
        defaults.set(enabled, forKey: "bluetoothEnabled")
        startTransports()
    }

    /// Turning pairing off weakens security, so it needs Face ID / passcode.
    func setRequirePairing(_ required: Bool) async {
        if !required {
            guard await confirmIdentity("Turn off Bluetooth pairing", weakensSecurity: true) else { return }
        }
        requirePairing = required
        defaults.set(required, forKey: "requirePairing")
        startTransports()
    }

    /// Sharing known addresses without asking needs Face ID / passcode to turn on.
    func setAutoSharePublicKeys(_ enabled: Bool) async {
        if enabled {
            guard await confirmIdentity("Share known addresses automatically", weakensSecurity: true) else { return }
        }
        autoSharePublicKeys = enabled
        defaults.set(enabled, forKey: "autoSharePublicKeys")
        let service = self.service!
        Task { await service.setAutoShareKnownPublicKeys(enabled) }
    }

    func setStrictBiometrics(_ enabled: Bool) async {
        do {
            try await vault.setStrictBiometrics(enabled)
        } catch {
            report(error)
        }
        strictBiometrics = vault.strictBiometrics
        strictUpgradePending = vault.strictUpgradePending
    }

    /// Face ID / passcode for actions that destroy keys or weaken security; while any key on the
    /// phone is strict (listed or from an earlier installation), only Face ID weakens security.
    /// Removing keys still takes the passcode, so wallets whose strict keys stopped working can be
    /// removed and restored. False if cancelled.
    private func confirmIdentity(_ reason: String, weakensSecurity: Bool = false) async -> Bool {
        do {
            try await vault.authenticate(reason: reason, biometricsOnly: weakensSecurity && vault.anyStrict)
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Wallets

    var hasKey: Bool { !wallets.isEmpty }

    var activeWallet: Wallet? { wallets.activeWallet }

    /// Adds a wallet from a recovery phrase or private key and makes it active.
    @discardableResult
    func addWallet(_ material: KeyMaterial, name: String = "") -> Bool {
        let isFirst = !hasKey
        do {
            try vault.addWallet(material, name: name)
            // The user is in the app (onboarding has no lock): don't lock them out of it.
            isUnlocked = true
            if isFirst { showConnectIntro = true }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func setActiveWallet(_ id: UUID) {
        do {
            try registry.update { $0.activate(id: id) }
        } catch {
            report(error)
        }
    }

    func renameWallet(_ id: UUID, to name: String) {
        do {
            try registry.update { try $0.rename(id: id, to: name) }
        } catch {
            report(error)
        }
    }

    /// Deletes a wallet's secret from this phone, after Face ID / passcode. Returns whether any
    /// wallet is left.
    @discardableResult
    func removeWallet(_ id: UUID) async -> Bool {
        guard await confirmIdentity("Remove the wallet from this phone") else { return true }
        do {
            try vault.removeWallet(id: id)
        } catch {
            report(error)
        }
        return !registry.snapshot.isEmpty
    }

    func removeAllWallets() async {
        guard await confirmIdentity("Remove all wallets from this phone") else { return }
        do {
            try vault.removeAllWallets()
        } catch {
            report(error)
        }
    }

    /// Restored wallets keep Strict Face ID: their keys only open with the biometrics enrolled
    /// when Strict Face ID was turned on.
    /// Returns false if Face ID / the passcode was cancelled, so the choice can be offered again.
    @discardableResult
    func restoreEarlierWallets() async -> Bool {
        guard await confirmIdentity("Restore wallets from an earlier installation") else { return false }
        isUnlocked = true
        vault.restoreEarlierWallets(earlierWallets)
        earlierWallets = []
        return true
    }

    @discardableResult
    func deleteEarlierWallets() async -> Bool {
        guard await confirmIdentity("Delete wallets from an earlier installation") else { return false }
        vault.deleteEarlierWallets(earlierWallets)
        earlierWallets = []
        return true
    }

    // MARK: Accounts

    /// The active wallet's accounts: what computers get.
    var accounts: [Account] { activeWallet?.accounts ?? [] }

    var canAddAccounts: Bool { activeWallet?.canAddAccounts ?? false }

    func account(id: UUID) -> (wallet: Wallet, account: Account)? {
        wallets.account(id: id)
    }

    /// The wallet and account that will answer a request, routed like the vault routes it.
    func target(of request: ApprovalRequest) -> (wallet: Wallet?, account: Account?) {
        // The live list, exactly as the vault will route the signature.
        let wallet = registry.snapshot.walletForRequest(path: request.path, expectedPublicKey: request.publicKey)
        return (wallet, wallet?.account(for: request.path))
    }

    /// "Account 2" (with several wallets, "Account 2 · Savings") when `accountId` is one of this
    /// phone's accounts: its implicit id, or the named account the user linked to it.
    func ownAccountLabel(for accountId: String) -> String? {
        for wallet in wallets.wallets {
            if let account = wallet.accounts.first(where: { $0.implicitAccountId == accountId || $0.accountId == accountId }) {
                return wallets.wallets.count > 1 ? "\(account.name) · \(wallet.name)" : account.name
            }
        }
        return nil
    }

    /// "Account 2" or, with several wallets, "Account 2 · Savings", for a history record.
    func accountLabel(for record: HistoryRecord) -> String? {
        guard let publicKey = record.publicKey, let owner = wallets.owner(ofPublicKey: publicKey) else { return nil }
        return wallets.wallets.count > 1 ? "\(owner.account.name) · \(owner.wallet.name)" : owner.account.name
    }

    /// Derives the key for `path` in the active wallet (Face ID) and adds the account.
    /// Returns false on failure.
    func addAccount(name: String, path: BIP32Path) async -> Bool {
        guard let wallet = activeWallet, wallet.canAddAccounts else { return false }
        guard AccountBook.isValidAccountPath(path) else {
            errorMessage = AccountError.invalidPath(path.description).description
            return false
        }
        guard wallet.book.account(for: path) == nil else {
            errorMessage = AccountError.duplicatePath(path.description).description
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? AccountBook.defaultName(for: path) : trimmed
        do {
            let key = try await vault.publicKey(walletID: wallet.id, path: path, reason: "Add \(label)")
            try registry.update { list in
                try list.updateBook(of: wallet.id) { try $0.add(path: path, publicKey: key, name: label) }
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func renameAccount(_ id: UUID, to name: String) {
        do {
            try registry.update { try $0.renameAccount(id: id, to: name) }
        } catch {
            report(error)
        }
    }

    /// Hides an account. Hosts must ask again before they get its public key.
    func removeAccount(_ id: UUID) {
        do {
            try registry.update { $0.removeAccount(id: id) }
        } catch {
            report(error)
        }
    }

    /// Sets the named NEAR account (alice.near) of an account; nil or "" clears it.
    func setAccountId(_ id: UUID, to accountId: String?) {
        do {
            try registry.update { try $0.setAccountId(accountID: id, to: accountId) }
        } catch {
            report(error)
        }
    }

    // MARK: Approvals

    func present(_ request: ApprovalRequest, continuation: CheckedContinuation<Bool, Never>) {
        if cancelledRequests.remove(request.id) != nil {
            continuation.resume(returning: false)
            return
        }
        if let current = pendingRequest { resolve(current.id, approved: false) }
        continuations[request.id] = continuation
        pendingRequest = request
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let id = request.id
        Task { [weak self] in
            try? await Task.sleep(for: AppModel.approvalTimeout)
            self?.resolve(id, approved: false)
        }
    }

    /// Called by the approval screen (and by the timeout).
    func resolve(_ id: UUID, approved: Bool) {
        if pendingRequest?.id == id { pendingRequest = nil }
        continuations.removeValue(forKey: id)?.resume(returning: approved)
    }

    /// Called when the requesting task is cancelled. It may run before `present`.
    func cancel(_ id: UUID) {
        if continuations[id] == nil {
            cancelledRequests.insert(id)
        } else {
            resolve(id, approved: false)
        }
    }

    func dismissLastResult() {
        lastResult = nil
    }

    /// Stops a large request while it arrives: the next chunk is refused, so the host gives up.
    /// Stops the upload `id` (the one on the progress card).
    func cancelReceiving(_ id: UUID) {
        guard receiving?.id == id else { return }
        isCancellingReceive = true
        let service = self.service!
        Task { await service.cancelReceiving(id) }
    }

    private func endReceiving() {
        receiving = nil
        isCancellingReceive = false
        receiveWatchdog?.cancel()
        receiveWatchdog = nil
    }

    /// A host that disconnects mid-upload sends nothing more; hide the progress after a pause.
    private func startReceiveWatchdog() {
        guard receiveWatchdog == nil else { return }
        receiveWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.receiving != nil else { return }
                if Date().timeIntervalSince(self.lastReceiveUpdate) > 30 {
                    self.endReceiving()
                    return
                }
            }
        }
    }

    private func handle(_ event: SignerEvent) {
        switch event {
        case let .receiving(progress):
            if receiving?.id != progress.id { isCancellingReceive = false }
            receiving = progress
            lastReceiveUpdate = Date()
            startReceiveWatchdog()
        case let .receiveEnded(id):
            if receiving?.id == id { endReceiving() }
        case .requestStarted:
            endReceiving()
        case let .requestFinished(record):
            lastResult = record
            if record.outcome == .approved {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            Task { await reloadHistory() }
        }
    }

    // MARK: History

    func reloadHistory() async {
        history = await historyStore.all()
    }

    func deleteHistory(_ record: HistoryRecord) {
        if lastResult?.id == record.id { lastResult = nil }
        Task {
            try? await historyStore.delete(id: record.id)
            await reloadHistory()
        }
    }

    func clearHistory() {
        lastResult = nil
        Task {
            try? await historyStore.clear()
            await reloadHistory()
        }
    }

    // MARK: Camera transfer

    /// Opens the camera; frames arrive through `cameraSaw`.
    func startCameraTransfer() {
        cameraReceiver.reset()
        cameraStartedAt = nil
        cameraSpeed = nil
        cameraTransfer = .scanning(nil)
        cameraScanner.onCode = { [weak self] text in self?.cameraSaw(text) }
        let scanner = cameraScanner
        Task { await scanner.start() }
    }

    /// Done, Cancel, or the scan screen closed. A request already with the signer keeps going:
    /// its approval screen is the way to reject it.
    func cancelCameraTransfer() {
        cameraScanner.stop()
        cameraScanner.onCode = nil
        cameraReceiver.reset()
        cameraTransfer = nil
        cameraSpeed = nil
    }

    /// One QR code the camera saw. Most are repeats or frames of a request still arriving.
    func cameraSaw(_ text: String) {
        guard case .scanning = cameraTransfer else { return }
        switch cameraReceiver.receive(text) {
        case .notAFrame, .duplicate, .otherSession:
            return
        case let .invalid(message):
            // Keep scanning: the computer keeps showing the codes, and the receiver started over.
            if errorMessage == nil { errorMessage = message }
            cameraStartedAt = nil
            cameraSpeed = nil
            cameraTransfer = .scanning(nil)
        case let .progress(progress):
            let now = Date()
            if let startedAt = cameraStartedAt, progress.total > 0 {
                let elapsed = now.timeIntervalSince(startedAt)
                let bytes = Double(progress.length) * Double(progress.known) / Double(progress.total)
                if elapsed > 0.5 { cameraSpeed = bytes / elapsed }
            } else {
                cameraStartedAt = now
            }
            cameraTransfer = .scanning(progress)
        case let .complete(message):
            let sessionId = cameraReceiver.sessionId ?? 0
            cameraScanner.stop()
            cameraSpeed = nil
            let request: OpticalRequest
            switch OpticalRequest.parse(message) {
            case let .success(parsed):
                request = parsed
            case let .failure(status):
                // Answered like Bluetooth, so the computer learns why and stops showing the codes.
                cameraTransfer = .response(OpticalResponse(sessionId: sessionId, status: status, result: Data()))
                return
            }
            cameraTransfer = .processing
            // The same path as a Bluetooth request from here: decode, show, approve, unlock, sign.
            let service = self.service!
            cameraTask = Task.detached { [weak self] in
                let result: Result<Data, StatusWord>
                if let kind = request.signKind {
                    result = await service.sign(kind: kind, path: request.path, payload: request.payload, transport: "Camera")
                } else {
                    result = await service.publicKey(path: request.path, display: true, transport: "Camera")
                }
                await self?.cameraFinished(sessionId: sessionId, result)
            }
        }
    }

    private func cameraFinished(sessionId: UInt32, _ result: Result<Data, StatusWord>) {
        cameraTask = nil
        guard cameraTransfer == .processing else { return }
        switch result {
        case let .success(data):
            cameraTransfer = .response(OpticalResponse(sessionId: sessionId, status: .ok, result: data))
        case .failure(.userRejected):
            // Whoever rejected it is at the computer; the last-result card says so.
            cameraTransfer = nil
        case let .failure(status):
            cameraTransfer = .response(OpticalResponse(sessionId: sessionId, status: status, result: Data()))
        }
    }

    // MARK: Errors

    /// Shows an error, except a cancelled Face ID prompt: the user meant to stop.
    private func report(_ error: Error) {
        if let keyError = error as? KeyError, keyError == .authenticationCancelled { return }
        if let error = error as? LocalizedError, let description = error.errorDescription {
            errorMessage = description
        } else {
            errorMessage = String(describing: error)
        }
    }

    #if DEBUG
    enum DemoRequest: String, CaseIterable, Identifiable {
        case tokenTransfer = "Send USDC"
        case intentsSwap = "Swap on NEAR Intents"
        case daoProposal = "DAO proposal"
        case daoVote = "DAO vote"
        case nearTransfer = "Send NEAR"

        var id: String { rawValue }
    }

    /// Sends a sample request through the full signing pipeline, for trying the UI without a host.
    func simulateIncomingRequest(_ demo: DemoRequest) {
        guard let account = accounts.first else { return }
        let usdc = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
        func call(_ method: String, _ args: String, deposit: U128 = U128(1)) -> Action {
            .functionCall(FunctionCallAction(methodName: method, args: Data(args.utf8), gas: 30_000_000_000_000, deposit: deposit))
        }
        func transaction(_ receiver: String, _ actions: [Action]) -> Data {
            Transaction(signerId: account.accountId ?? "alice.near", publicKey: .ed25519(account.publicKey), nonce: 42,
                        receiverId: receiver, blockHash: Data(repeating: 7, count: 32), actions: actions).borsh
        }
        let kind: SignerService.SignKind
        let payload: Data
        switch demo {
        case .tokenTransfer:
            kind = .transaction
            payload = transaction(usdc, [call("ft_transfer", #"{"receiver_id":"bob.near","amount":"250000000","memo":"Invoice 42"}"#)])
        case .intentsSwap:
            kind = .nep413
            let deadline = ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))
            let message = """
                {"signer_id":"\(account.accountId ?? "alice.near")","deadline":"\(deadline)","intents":[{"intent":"token_diff",\
                "diff":{"nep141:wrap.near":"-10000000000000000000000000","nep141:\(usdc)":"29800000"}}]}
                """
            payload = NEP413Payload(message: message, nonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                                    recipient: "intents.near", callbackUrl: nil).borsh
        case .daoProposal:
            kind = .transaction
            payload = transaction("design.sputnik-dao.near", [call("add_proposal", """
                {"proposal":{"description":"Pay for the new logo","kind":{"Transfer":{"token_id":"\(usdc)",\
                "receiver_id":"bob.near","amount":"500000000"}}}}
                """, deposit: U128(decimal: "100000000000000000000000")!)])
        case .daoVote:
            kind = .transaction
            payload = transaction("design.sputnik-dao.near", [call("act_proposal", """
                {"id":12,"action":"VoteApprove","proposal":{"Transfer":{"token_id":"","receiver_id":"bob.near",\
                "amount":"5000000000000000000000000"}}}
                """, deposit: .zero)])
        case .nearTransfer:
            kind = .transaction
            payload = transaction("bob.near", [.transfer(deposit: U128(decimal: "1250000000000000000000000")!)])
        }
        let service = self.service!
        let path = account.path
        Task.detached {
            _ = await service.sign(kind: kind, path: path, payload: payload, transport: "Demo")
        }
    }
    #endif
}

// MARK: - Security checklist

extension AppModel {
    var securityItems: [SecurityItem] {
        let enclave = SecureKeyVault.usesSecureEnclave
        let passcode = SecureKeyVault.deviceHasPasscode
        let offline = !networkAvailable
        return [
            SecurityItem(
                id: "enclave", title: "Hardware key protection",
                detail: enclave ? "Your key is sealed by the Secure Enclave and opens only with Face ID or your passcode."
                    : "This device has no Secure Enclave. Use test keys only.",
                done: enclave),
            SecurityItem(
                id: "passcode", title: "Device passcode",
                detail: passcode ? "A passcode protects this phone." : "Set a passcode in the Settings app.",
                done: passcode),
            SecurityItem(
                id: "offline", title: "Airplane Mode",
                detail: offline ? "No Wi-Fi or cellular connection."
                    : "Turn on Airplane Mode, then turn Bluetooth back on. Signing doesn't need the internet.",
                done: offline),
            SecurityItem(
                id: "lock", title: "App lock",
                detail: appLockEnabled ? "NEAR Signer asks for Face ID or your passcode when you open it."
                    : "Turn on \"Lock app\" in Settings.",
                done: appLockEnabled),
            SecurityItem(
                id: "pairing", title: "Bluetooth pairing",
                detail: requirePairing ? "Computers must pair before they can send requests."
                    : "Turn on \"Require pairing\" in Settings › Advanced.",
                done: requirePairing),
        ]
    }

    var securityComplete: Bool { securityItems.allSatisfy(\.done) }
}
