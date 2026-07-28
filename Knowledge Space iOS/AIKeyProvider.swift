//
//  AIKeyProvider.swift
//  LiquidAuthorTextCore
//
//  Supplies the API keys for the cloud AI providers. The keys are not
//  compiled into the app: they are fetched from an encrypted blob published
//  at a static URL, so a compromised key can be rotated without an app
//  update (see the author-key-rotation repository / "Author Keys" app).
//
//  Blob format: base64( nonce[12] + AES-256-GCM ciphertext + tag[16] )
//  containing JSON { v, openai, anthropic, gemini, updated }.
//

import CryptoKit
import Foundation

public final class AIKeyProvider {

    public static let shared = AIKeyProvider()

    /// Tried in order; the first readable blob wins.
    private static let blobURLs = [
        "https://raw.githubusercontent.com/frodehegland/author-config/main/key.blob",
    ]

    private static let cacheDefaultsKey = "AIKeyProviderCachedBlob"

    private let queue = DispatchQueue(label: "AIKeyProvider")
    private var keys: [String: String] = [:]
    private var lastFetch: Date?
    private var refreshTask: Task<Void, Never>?

    private init() {
        if let cached = UserDefaults.standard.string(forKey: Self.cacheDefaultsKey),
           let decrypted = Self.decrypt(blob: cached) {
            keys = decrypted
        }
    }

    // MARK: Public API

    /// The current key for a provider, or nil if none is available yet.
    /// A nil result schedules a background refresh so a retry can succeed.
    public func key(for name: String) -> String? {
        let value = queue.sync { keys[name] }
        if value?.isEmpty ?? true {
            refreshSoon()
            return nil
        }
        return value
    }

    /// Fetches the latest blob. Safe to call repeatedly; runs at most one
    /// fetch at a time and no more than once per minute unless forced.
    public func refresh(force: Bool = false) async {
        let recent = queue.sync { lastFetch.map { Date().timeIntervalSince($0) < 60 } ?? false }
        if recent && !force { return }
        queue.sync { lastFetch = Date() }

        for urlString in Self.blobURLs {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let blob = String(data: data, encoding: .utf8),
                  let decrypted = Self.decrypt(blob: blob)
            else { continue }

            queue.sync { keys = decrypted }
            UserDefaults.standard.set(blob.trimmingCharacters(in: .whitespacesAndNewlines),
                                      forKey: Self.cacheDefaultsKey)
            return
        }
    }

    /// Called once at app launch.
    public func start() {
        refreshSoon()
    }

    private func refreshSoon() {
        queue.sync {
            guard refreshTask == nil else { return }
            refreshTask = Task { [weak self] in
                await self?.refresh()
                self?.queue.sync { self?.refreshTask = nil }
            }
        }
    }

    // MARK: Decryption

    private static func decrypt(blob: String) -> [String: String]? {
        guard let raw = Data(base64Encoded: blob.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count > 28
        else { return nil }

        guard let nonce = try? AES.GCM.Nonce(data: raw.prefix(12)),
              let box = try? AES.GCM.SealedBox(nonce: nonce,
                                               ciphertext: raw.dropFirst(12).dropLast(16),
                                               tag: raw.suffix(16)),
              let plain = try? AES.GCM.open(box, using: secret),
              let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
        else { return nil }

        var result: [String: String] = [:]
        for (key, value) in json {
            if let string = value as? String { result[key] = string }
        }
        return result
    }

    // The blob secret, assembled at runtime rather than stored as a literal.
    private static let noise: [UInt8] = [0x6f, 0x25, 0x0e, 0x4e, 0x7f, 0x89, 0xee, 0x4e, 0xb3, 0x7e, 0x4b, 0xf5, 0xae, 0x9b, 0xa5, 0xbf, 0x7f, 0x6a, 0x3f, 0x43, 0xab, 0xf3, 0x93, 0x2a, 0xde, 0xa0, 0x07, 0x32, 0xdf, 0x81, 0x03, 0x3e]
    private static let material: [UInt8] = [0xee, 0x89, 0xde, 0x3b, 0xcc, 0x0f, 0xc4, 0xfa, 0x55, 0x2d, 0x96, 0x90, 0xde, 0x28, 0x6d, 0xdf, 0x8f, 0x09, 0x9f, 0x64, 0x98, 0x88, 0xcb, 0x4a, 0xbe, 0xc7, 0xcb, 0x3f, 0xa3, 0xd2, 0x0d, 0x5f]

    private static let secret = SymmetricKey(data: Data(zip(material, noise).map(^)))
}
