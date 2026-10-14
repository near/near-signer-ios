// CryptoKit on Apple platforms, swift-crypto (same API) elsewhere.
#if canImport(CryptoKit)
@_exported import CryptoKit
#else
@_exported import Crypto
#endif
