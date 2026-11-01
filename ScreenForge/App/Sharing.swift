import AppKit
import Combine
import CryptoKit
import Foundation
import Security

/// Sharing surface.
///
/// Local delivery uses the system share sheet (AirDrop, Messages, Mail, Save to
/// Photos, third-party share extensions). Optional cloud links are uploaded to a
/// configured endpoint; without one the app behaves like a local-first editor.
@MainActor
public enum SharingService {
    public static func presentShareSheet(for url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let view = window.contentView {
            let rect = NSRect(
                x: view.bounds.midX - 1,
                y: view.bounds.midY - 1,
                width: 2,
                height: 2
            )
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        } else if let service = NSSharingService(named: .sendViaAirDrop) {
            service.perform(withItems: [url])
        }
    }

    public static func shareViaAirDrop(_ url: URL) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
    }

    public static var shareEndpoint: URL? {
        guard let raw = ProcessInfo.processInfo.environment["SCREENFORGE_SHARE_ENDPOINT"],
              let url = URL(string: raw) else { return nil }
        return url
    }

    /// Uploads the export to a sharing endpoint and returns the public URL.
    ///
    /// The endpoint contract is intentionally tiny: multipart field `file`, JSON
    /// response `{ "url": "https://…" }`.
    public static func upload(_ fileURL: URL) async throws -> URL {
        guard let endpoint = shareEndpoint else {
            throw SharingError.notConfigured
        }
        let data = try Data(contentsOf: fileURL)
        let boundary = "ScreenForge-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SharingError.uploadFailed
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let raw = json["url"] as? String,
              let url = URL(string: raw) else {
            throw SharingError.invalidResponse
        }
        return url
    }

    public enum SharingError: LocalizedError {
        case notConfigured
        case uploadFailed
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Cloud links need a sharing endpoint. Set SCREENFORGE_SHARE_ENDPOINT or use AirDrop/Messages."
            case .uploadFailed:
                "The sharing service rejected the upload."
            case .invalidResponse:
                "The sharing service returned an unexpected response."
            }
        }
    }
}

// MARK: - Updates

public struct UpdateInfo: Sendable, Equatable {
    public var version: String
    public var downloadURL: URL
    public var notes: String
}

public enum UpdateChecker {
    public static var feedURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["SCREENFORGE_UPDATE_FEED"] else {
            return nil
        }
        return URL(string: raw)
    }

    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    /// Fetches a small JSON appcast: `{ "version": "1.2.0", "url": "…", "notes": "…" }`.
    public static func check() async -> UpdateInfo? {
        guard let feedURL else { return nil }
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let rawURL = json["url"] as? String,
              let url = URL(string: rawURL) else {
            return nil
        }

        guard compareVersions(version, currentVersion) > 0 else { return nil }
        return UpdateInfo(
            version: version,
            downloadURL: url,
            notes: json["notes"] as? String ?? ""
        )
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }
}

// MARK: - Licensing

/// Offline license verification with Ed25519.
///
/// Keys are stored in the Keychain and verified locally, mirroring Screen Studio's
/// signed-license model. The public key comes from `SCREENFORGE_LICENSE_PUBLIC_KEY`
/// (base64, raw 32 bytes) so a real licence server can be plugged in without a code
/// change; otherwise the manager reports that licensing is not configured.
public final class LicenseManager: ObservableObject, @unchecked Sendable {
    public static let shared = LicenseManager()

    public struct License: Codable, Sendable, Equatable {
        public var email: String
        public var tier: String
        /// ISO-8601 date.
        public var expiresAt: String
    }

    public struct State: Sendable, Equatable {
        public var isConfigured: Bool
        public var license: License?
        public var message: String
    }

    @Published public private(set) var state: State

    private let service = "studio.screenforge.license"
    private let account = "license-key"

    public init() {
        let configured = Self.publicKey != nil
        let stored = Self.readKeychain(service: service, account: account)
        if let stored, let license = Self.verify(key: stored) {
            state = State(isConfigured: configured, license: license, message: "Licensed to \(license.email)")
        } else {
            state = State(
                isConfigured: configured,
                license: nil,
                message: configured ? "No active license" : "Licensing is not configured in this build"
            )
        }
    }

    public func activate(key: String) {
        guard let license = Self.verify(key: key) else {
            state.message = "That license key is invalid or expired."
            return
        }
        Self.writeKeychain(key, service: service, account: account)
        state = State(isConfigured: true, license: license, message: "Licensed to \(license.email)")
    }

    public func deactivate() {
        Self.deleteKeychain(service: service, account: account)
        state = State(isConfigured: Self.publicKey != nil, license: nil, message: "No active license")
    }

    private static var publicKey: Curve25519.Signing.PublicKey? {
        guard let raw = ProcessInfo.processInfo.environment["SCREENFORGE_LICENSE_PUBLIC_KEY"],
              let data = Data(base64Encoded: raw) else {
            return nil
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    /// Key format: `base64(payloadJSON).base64(signature)`.
    static func verify(key: String) -> License? {
        let parts = key.split(separator: ".")
        guard parts.count == 2,
              let payloadData = Data(base64Encoded: String(parts[0])),
              let signature = Data(base64Encoded: String(parts[1])),
              let publicKey else {
            return nil
        }
        guard (try? publicKey.isValidSignature(signature, for: payloadData)) == true else {
            return nil
        }
        guard let license = try? JSONDecoder().decode(License.self, from: payloadData) else {
            return nil
        }
        if let expiry = ISO8601Coding.date(from: license.expiresAt), expiry < Date() {
            return nil
        }
        return license
    }

    // MARK: Keychain

    private static func readKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func deleteKeychain(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
