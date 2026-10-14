import Foundation

/// A fungible token whose symbol and decimals are known offline.
public struct Token: Equatable, Sendable {
    /// Token contract, "" for native NEAR, or the full id of a NEAR Intents NEP-245 token
    /// (`nep245:<contract>:<token id>`).
    public let contract: String
    public let symbol: String
    public let name: String
    public let decimals: Int
    /// Asset name of the icon in the iOS app, if there is one.
    public let icon: String?

    public init(contract: String, symbol: String, name: String, decimals: Int, icon: String?) {
        self.contract = contract
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.icon = icon
    }
}

/// Tokens the signer recognizes. A token's own metadata cannot be fetched offline and a host
/// could lie about it, so symbols and decimals come only from this list. Every mainnet entry was
/// checked against the contract's `ft_metadata` (scripts/gen-token-icons.mjs fetches the icons).
public enum TokenRegistry {
    public static let near = Token(contract: "", symbol: "NEAR", name: "NEAR", decimals: 24, icon: "token-near")

    public static let tokens: [Token] = [
        Token(contract: "wrap.near", symbol: "wNEAR", name: "Wrapped NEAR", decimals: 24, icon: "token-near"),
        Token(contract: "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1", symbol: "USDC", name: "USDC", decimals: 6, icon: "token-usdc"),
        Token(contract: "usdt.tether-token.near", symbol: "USDt", name: "Tether USD", decimals: 6, icon: "token-usdt"),
        Token(contract: "a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.factory.bridge.near", symbol: "USDC.e", name: "Bridged USDC", decimals: 6, icon: "token-usdc-e"),
        Token(contract: "dac17f958d2ee523a2206206994597c13d831ec7.factory.bridge.near", symbol: "USDT.e", name: "Bridged Tether USD", decimals: 6, icon: "token-usdt-e"),
        Token(contract: "2260fac5e5542a773aa44fbcfedf7c193bc2c599.factory.bridge.near", symbol: "WBTC", name: "Wrapped BTC", decimals: 8, icon: "token-wbtc"),
        Token(contract: "6b175474e89094c44da98b954eedeac495271d0f.factory.bridge.near", symbol: "DAI", name: "Dai Stablecoin", decimals: 18, icon: "token-dai"),
        Token(contract: "aaaaaa20d9e0e2461697782ef11675f668207961.factory.bridge.near", symbol: "AURORA", name: "Aurora", decimals: 18, icon: "token-aurora"),
        Token(contract: "token.v2.ref-finance.near", symbol: "REF", name: "Ref Finance", decimals: 18, icon: "token-ref"),
        Token(contract: "meta-pool.near", symbol: "stNEAR", name: "Staked NEAR", decimals: 24, icon: "token-stnear"),
        Token(contract: "linear-protocol.near", symbol: "LiNEAR", name: "LiNEAR", decimals: 24, icon: "token-linear"),
        Token(contract: "token.sweat", symbol: "SWEAT", name: "SWEAT", decimals: 18, icon: "token-sweat"),
        Token(contract: "nbtc.bridge.near", symbol: "nBTC", name: "NEAR Bitcoin", decimals: 8, icon: "token-nbtc"),
        Token(contract: "eth.bridge.near", symbol: "ETH", name: "Ether (bridged)", decimals: 18, icon: "token-eth-bridge"),
        Token(contract: "btc.omft.near", symbol: "BTC", name: "Bitcoin", decimals: 8, icon: "token-btc"),
        Token(contract: "eth.omft.near", symbol: "ETH", name: "Ethereum", decimals: 18, icon: "token-eth"),
        Token(contract: "sol.omft.near", symbol: "SOL", name: "Solana", decimals: 9, icon: "token-sol"),
        Token(contract: "zec.omft.near", symbol: "ZEC", name: "Zcash", decimals: 8, icon: "token-zec"),
        Token(contract: "xrp.omft.near", symbol: "XRP", name: "XRP", decimals: 6, icon: "token-xrp"),
        Token(contract: "doge.omft.near", symbol: "DOGE", name: "Dogecoin", decimals: 8, icon: nil),
        // USDC and USDT from other chains, as NEAR Intents holds them: NEP-141 tokens of its own
        // bridge (`*.omft.near`) and NEP-245 tokens of HOT Bridge (`v2_1.omni.hot.tg`). Taken from
        // the NEAR Intents app's token list; symbols and decimals checked against `ft_metadata` and
        // `mt_metadata_base_by_token_id`. The BNB Chain ones have 18 decimals.
        Token(contract: "eth-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.omft.near", symbol: "USDC", name: "USD Coin (Ethereum)", decimals: 6, icon: "token-usdc"),
        Token(contract: "base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near", symbol: "USDC", name: "USD Coin (Base)", decimals: 6, icon: "token-usdc"),
        Token(contract: "arb-0xaf88d065e77c8cc2239327c5edb3a432268e5831.omft.near", symbol: "USDC", name: "USD Coin (Arbitrum)", decimals: 6, icon: "token-usdc"),
        Token(contract: "sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near", symbol: "USDC", name: "USD Coin (Solana)", decimals: 6, icon: "token-usdc"),
        Token(contract: "gnosis-0x2a22f9c3b484c3629090feed35f17ff8f88f76f0.omft.near", symbol: "USDC", name: "USD Coin (Gnosis)", decimals: 6, icon: "token-usdc"),
        Token(contract: "nep245:v2_1.omni.hot.tg:137_qiStmoQJDQPTebaPjgx5VBxZv6L", symbol: "USDC", name: "USD Coin (Polygon)", decimals: 6, icon: "token-usdc"),
        Token(contract: "nep245:v2_1.omni.hot.tg:56_2w93GqMcEmQFDru84j3HZZWt557r", symbol: "USDC", name: "USD Coin (BNB Chain)", decimals: 18, icon: "token-usdc"),
        Token(contract: "sui-c1b81ecaf27933252d31a963bc5e9458f13c18ce.omft.near", symbol: "USDC", name: "USD Coin (Sui)", decimals: 6, icon: "token-usdc"),
        Token(contract: "nep245:v2_1.omni.hot.tg:1100_111bzQBB65GxAPAVoxqmMcgYo5oS3txhqs1Uh1cgahKQUeTUq1TJu", symbol: "USDC", name: "USD Coin (Stellar)", decimals: 7, icon: "token-usdc"),
        Token(contract: "nep245:v2_1.omni.hot.tg:10_A2ewyUyDp6qsue1jqZsGypkCxRJ", symbol: "USDC", name: "USD Coin (Optimism)", decimals: 6, icon: "token-usdc"),
        Token(contract: "nep245:v2_1.omni.hot.tg:43114_3atVJH3r5c4GqiSYmg9fECvjc47o", symbol: "USDC", name: "USD Coin (Avalanche)", decimals: 6, icon: "token-usdc"),
        Token(contract: "nep245:v2_1.omni.hot.tg:196_2dK9kLNR7Ekq7su8FxNGiUW3djTw", symbol: "USDC", name: "USD Coin (X Layer)", decimals: 6, icon: "token-usdc"),
        Token(contract: "nep245:v2_1.omni.hot.tg:143_2dmLwYWkCQKyTjeUPAsGJuiVLbFx", symbol: "USDC", name: "USD Coin (Monad)", decimals: 6, icon: "token-usdc"),
        Token(contract: "aptos-34ee497f210c5a511e8d5b53bc56d75b63612bb5.omft.near", symbol: "USDC", name: "USD Coin (Aptos)", decimals: 6, icon: "token-usdc"),
        Token(contract: "eth-0xdac17f958d2ee523a2206206994597c13d831ec7.omft.near", symbol: "USDT", name: "Tether USD (Ethereum)", decimals: 6, icon: "token-usdt"),
        Token(contract: "arb-0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9.omft.near", symbol: "USDT", name: "Tether USD (Arbitrum)", decimals: 6, icon: "token-usdt"),
        Token(contract: "sol-c800a4bd850783ccb82c2b2c7e84175443606352.omft.near", symbol: "USDT", name: "Tether USD (Solana)", decimals: 6, icon: "token-usdt"),
        Token(contract: "tron-d28a265909efecdcee7c5028585214ea0b96f015.omft.near", symbol: "USDT", name: "Tether USD (Tron)", decimals: 6, icon: "token-usdt"),
        Token(contract: "nep245:v2_1.omni.hot.tg:137_3hpYoaLtt8MP1Z2GH1U473DMRKgr", symbol: "USDT", name: "Tether USD (Polygon)", decimals: 6, icon: "token-usdt"),
        Token(contract: "nep245:v2_1.omni.hot.tg:56_2CMMyVTGZkeyNZTSvS5sarzfir6g", symbol: "USDT", name: "Tether USD (BNB Chain)", decimals: 18, icon: "token-usdt"),
        Token(contract: "nep245:v2_1.omni.hot.tg:1117_3tsdfyziyc7EJbP2aULWSKU4toBaAcN4FdTgfm5W1mC4ouR", symbol: "USDT", name: "Tether USD (TON)", decimals: 6, icon: "token-usdt"),
        Token(contract: "nep245:v2_1.omni.hot.tg:43114_372BeH7ENZieCaabwkbWkBiTTgXp", symbol: "USDT", name: "Tether USD (Avalanche)", decimals: 6, icon: "token-usdt"),
        Token(contract: "nep245:v2_1.omni.hot.tg:10_359RPSJVdTxwTJT9TyGssr2rFoWo", symbol: "USDT", name: "Tether USD (Optimism)", decimals: 6, icon: "token-usdt"),
        Token(contract: "aptos-88cb7619440a914fe6400149a12b443c3ac21d59.omft.near", symbol: "USDT", name: "Tether USD (Aptos)", decimals: 6, icon: "token-usdt"),
        Token(contract: "bera-0x779ded0c9e1022225f8e0630b35a9b54be713736.omft.near", symbol: "USDT0", name: "USDT0 (Berachain)", decimals: 6, icon: "token-usdt"),
        Token(contract: "nep245:v2_1.omni.hot.tg:196_2fezDCvVYRsG8wrK6deJ2VRPiAS1", symbol: "USDT0", name: "USDT0 (X Layer)", decimals: 6, icon: "token-usdt"),
        Token(contract: "nep245:v2_1.omni.hot.tg:143_4EJiJxSALvGoTZbnc8K7Ft9533et", symbol: "USDT", name: "Tether USD (Monad)", decimals: 6, icon: "token-usdt"),
        Token(contract: "nep245:v2_1.omni.hot.tg:9745_3aL9skCy1yhPoDB8oKMmRHRN7SJW", symbol: "USDT", name: "Tether USD (Plasma)", decimals: 6, icon: "token-usdt"),
        Token(contract: "plasma-0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb.omft.near", symbol: "USDT", name: "Tether USD (Plasma)", decimals: 6, icon: "token-usdt"),
        Token(contract: "gnosis-0x4ecaba5870353805a9f068101a40e0f32ed605c6.omft.near", symbol: "USDT", name: "Tether USD (Gnosis)", decimals: 6, icon: "token-usdt"),
        Token(contract: "wrap.testnet", symbol: "wNEAR", name: "Wrapped NEAR (testnet)", decimals: 24, icon: "token-near"),
    ]

    private static let byContract: [String: Token] = Dictionary(tokens.map { ($0.contract, $0) }, uniquingKeysWith: { first, _ in first })

    public static func token(contract: String) -> Token? {
        contract.isEmpty ? near : byContract[contract]
    }

    /// Issuers of NEAR Intents internal tokens (`imt:<issuer>:<token>`) whose tokens stand for the
    /// token they are named after. Tokens of any other issuer are shown with a warning.
    public static let trustedIssuers: Set<String> = [
        // Mints the FAR chain's tokens in intents.far (confirmed by the NEAR Signer maintainers).
        "51e8f94d77b5e90dc9852ca6113771e11e8382ce69473a75e313e41665de7cbe",
    ]

    /// Wrapped-NEAR contracts (near_deposit / near_withdraw).
    public static func isWrappedNear(_ contract: String) -> Bool {
        contract == "wrap.near" || contract == "wrap.testnet"
    }
}

/// An amount of a token, formatted only when the token is known.
public struct TokenAmount: Equatable, Sendable {
    /// Smallest units.
    public var raw: U128
    /// Contract, "" for NEAR, or a NEAR Intents token id such as `nep245:contract:id` or
    /// `imt:issuer:nep141:wrap.near`.
    public var tokenId: String
    public var token: Token?

    public init(raw: U128, tokenId: String) {
        self.raw = raw
        self.tokenId = tokenId
        self.token = TokenAmount.knownToken(for: tokenId)
    }

    /// Parses a decimal string (as NEAR JSON encodes u128). Nil if it is not a number.
    public init?(raw: String, tokenId: String) {
        guard let value = U128(decimal: raw) else { return nil }
        self.init(raw: value, tokenId: tokenId)
    }

    /// NEAR Intents token ids name the contract after a standard prefix. An internal token
    /// (`imt:<issuer>:<name>`) takes the decimals and symbol of the token it is named after.
    private static func knownToken(for tokenId: String) -> Token? {
        if let internalToken = internalToken(tokenId) {
            return internalToken.name.hasPrefix("imt:") ? nil : knownToken(for: internalToken.name)
        }
        if tokenId.hasPrefix("nep141:") { return TokenRegistry.token(contract: String(tokenId.dropFirst(7))) }
        // A plain contract, or a NEP-245 token listed under its full id.
        return TokenRegistry.token(contract: tokenId)
    }

    /// Splits `imt:<issuer>:<name>`, a token minted inside NEAR Intents. Account ids have no
    /// colons, so the issuer ends at the second one; the name is whatever the issuer chose.
    static func internalToken(_ tokenId: String) -> (issuer: String, name: String)? {
        guard tokenId.hasPrefix("imt:") else { return nil }
        let rest = tokenId.dropFirst(4)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let issuer = String(rest[..<colon])
        let name = String(rest[rest.index(after: colon)...])
        return issuer.isEmpty || name.isEmpty ? nil : (issuer, name)
    }

    public var isKnown: Bool { token != nil }

    /// The account that minted an internal NEAR Intents token, nil for any other token.
    public var issuer: String? { TokenAmount.internalToken(tokenId)?.issuer }

    /// An internal token whose issuer is not in `TokenRegistry.trustedIssuers`.
    public var hasUntrustedIssuer: Bool { issuer.map { !TokenRegistry.trustedIssuers.contains($0) } ?? false }

    /// "1,000.5" for known tokens; the raw integer otherwise.
    public var formatted: String {
        guard let token else { return raw.description }
        return NearFormat.tokenAmount(raw, decimals: token.decimals)
    }

    /// "USDC", or the contract for an unknown token.
    public var symbol: String {
        if let token { return token.symbol }
        if tokenId.hasPrefix("nep141:") { return String(tokenId.dropFirst(7)) }
        return tokenId
    }

    /// "1,000.5 USDC", or "1000500 units of foo.near" for an unknown token. Internal NEAR Intents
    /// tokens name their issuer: "1 wNEAR issued by bridge.far".
    public var text: String {
        guard isKnown else { return "\(raw) units of \(symbol)" }
        return issuer.map { "\(formatted) \(symbol) issued by \($0)" } ?? "\(formatted) \(symbol)"
    }

    /// For titles: "1,000.5 USDC" or "foo.near tokens".
    public var shortText: String {
        isKnown ? "\(formatted) \(symbol)" : "\(symbol) tokens"
    }
}

extension NearFormat {
    /// Thousands separator: a narrow no-break space, which no locale reads as a decimal point
    /// (a comma would read as one in much of Europe).
    public static let groupingSeparator: Character = "\u{202F}"

    /// Exact decimal rendering with thousands separators: 1234567890 with 6 decimals is
    /// "1 234.56789" (narrow spaces). Nothing is rounded.
    public static func tokenAmount(_ raw: U128, decimals: Int) -> String {
        let digits = raw.description
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let integer = String(padded.dropLast(decimals))
        var fraction = String(padded.suffix(decimals))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        var grouped = ""
        for (index, character) in integer.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { grouped.append(groupingSeparator) }
            grouped.append(character)
        }
        let whole = String(grouped.reversed())
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }
}
