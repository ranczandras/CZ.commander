import Foundation
import CryptoKit
import Network
import Security

// Dropbox in a panel: sign in with the user's browser (OAuth 2 + PKCE, no password ever reaches
// the app), browse your own Dropbox, folders shared with you (also the ones not added to your
// Dropbox) and shared links, and copy files in and out with the normal progress dialog.
//
// The app key belongs to the "CZ.commander" app in the Dropbox App Console; it is public by
// design (PKCE needs no secret). The refresh token lives in the macOS Keychain.

public enum DropboxConfig {
    public static let appKey = "sz3517amssvkl80"
    public static let redirectPort: UInt16 = 53682
    public static let redirectPath = "/czcommander-dropbox"
    public static var redirectURI: String { "http://localhost:\(redirectPort)\(redirectPath)" }
    /// Only the user scopes the panel needs (the app also has team scopes we never request).
    public static let scopes = [
        "account_info.read",
        "files.metadata.read", "files.metadata.write",
        "files.content.read", "files.content.write",
        "sharing.read",
    ]
}

public struct DropboxError: LocalizedError, Sendable {
    public let message: String
    public let status: Int
    public init(_ message: String, status: Int = 0) {
        self.message = message
        self.status = status
    }
    public var errorDescription: String? { message }
}

// MARK: - Locations

/// A place in the Dropbox panel. Encoded into `FileItem.fullPath` as "dbx:<token>".
public enum DropboxLocation: Equatable, Sendable {
    /// Your own Dropbox: "/" is the root.
    case own(String)
    /// Virtual list of every folder shared with you.
    case sharedWithMe
    /// Inside a shared folder by namespace id (works whether or not it was added to your Dropbox).
    case namespace(id: String, path: String)
    /// Inside a shared link (`path` relative to the link's folder, "" = its top).
    case link(url: String, path: String)

    public static let prefix = "dbx:"

    public var token: String {
        switch self {
        case .own(let p): return p.isEmpty ? "/" : p
        case .sharedWithMe: return "shared:"
        case .namespace(let id, let p): return "ns:" + id + p
        case .link(let url, let p):
            let enc = Data(url.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "link:" + enc + p
        }
    }

    public var fullPath: String { Self.prefix + token }

    public static func isDropboxPath(_ path: String) -> Bool { path.hasPrefix(prefix) }

    public init?(fullPath: String) {
        guard fullPath.hasPrefix(Self.prefix) else { return nil }
        self.init(token: String(fullPath.dropFirst(Self.prefix.count)))
    }

    public init?(token t: String) {
        if t == "shared:" { self = .sharedWithMe; return }
        if t.hasPrefix("ns:") {
            let rest = t.dropFirst(3)
            let id = String(rest.prefix { $0 != "/" })
            guard !id.isEmpty else { return nil }
            self = .namespace(id: id, path: String(rest.dropFirst(id.count)))
            return
        }
        if t.hasPrefix("link:") {
            let rest = t.dropFirst(5)
            let enc = String(rest.prefix { $0 != "/" })
            var b64 = enc.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64), let url = String(data: data, encoding: .utf8) else { return nil }
            self = .link(url: url, path: String(rest.dropFirst(enc.count)))
            return
        }
        guard t.hasPrefix("/") else { return nil }
        self = .own(t)
    }

    /// Path for files/* endpoints ("" = root of your Dropbox). nil for virtual / link places.
    public var apiPath: String? {
        switch self {
        case .own(let p): return p == "/" ? "" : p
        case .namespace(let id, let p): return "ns:" + id + p
        case .sharedWithMe, .link: return nil
        }
    }

    public var isRoot: Bool {
        switch self {
        case .own(let p): return p == "/" || p.isEmpty
        case .sharedWithMe: return false
        case .namespace(_, let p), .link(_, let p): return p.isEmpty
        }
    }

    public func appending(_ name: String) -> DropboxLocation {
        switch self {
        case .own(let p): return .own((p == "/" ? "" : p) + "/" + name)
        case .sharedWithMe: return self
        case .namespace(let id, let p): return .namespace(id: id, path: p + "/" + name)
        case .link(let url, let p): return .link(url: url, path: p + "/" + name)
        }
    }

    /// One level up; shared folders and links go back to "Shared with me" / your root.
    public var parent: DropboxLocation {
        func up(_ p: String) -> String {
            let parent = (p as NSString).deletingLastPathComponent
            return parent == "/" ? "" : parent
        }
        switch self {
        case .own(let p):
            let u = up(p)
            return .own(u.isEmpty ? "/" : u)
        case .sharedWithMe: return .own("/")
        case .namespace(let id, let p): return p.isEmpty ? .sharedWithMe : .namespace(id: id, path: up(p))
        case .link(let url, let p): return p.isEmpty ? .own("/") : .link(url: url, path: up(p))
        }
    }

    public var lastName: String {
        switch self {
        case .own(let p), .namespace(_, let p), .link(_, let p): return (p as NSString).lastPathComponent
        case .sharedWithMe: return "Shared with me"
        }
    }

    public var displayPath: String {
        switch self {
        case .own(let p): return "Dropbox:" + (p.isEmpty ? "/" : p)
        case .sharedWithMe: return "Dropbox: Shared with me"
        case .namespace(_, let p): return "Dropbox: Shared" + (p.isEmpty ? "/" : p)
        case .link(_, let p): return "Dropbox: Link" + (p.isEmpty ? "/" : p)
        }
    }

    /// Writable through files/* (own Dropbox and shared folders you can edit).
    public var supportsWrite: Bool { apiPath != nil }
}

// MARK: - Entries

public struct DropboxEntry: Sendable, Equatable {
    public let name: String
    public let isFolder: Bool
    public let size: Int64
    public let modified: Date?
    public let location: DropboxLocation
    public let contentHash: String?

    public init(name: String, isFolder: Bool, size: Int64, modified: Date?, location: DropboxLocation, contentHash: String? = nil) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.location = location
        self.contentHash = contentHash
    }

    public func fileItem() -> FileItem {
        var item = FileItem(name: name, fullPath: location.fullPath, isDirectory: isFolder)
        item.size = size
        if let modified { item.modificationDate = modified }
        return item
    }

    static let dateParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Builds an entry from a files/list_folder "entries" element.
    static func from(json: [String: Any], in parent: DropboxLocation) -> DropboxEntry? {
        guard let tag = json[".tag"] as? String, let name = json["name"] as? String, tag != "deleted" else { return nil }
        let isFolder = tag == "folder"
        let date = (json["server_modified"] as? String).flatMap { dateParser.date(from: $0) }
        let size = (json["size"] as? NSNumber)?.int64Value ?? 0
        return DropboxEntry(name: name, isFolder: isFolder, size: size, modified: date,
                            location: parent.appending(name), contentHash: json["content_hash"] as? String)
    }
}

// MARK: - Keychain

enum DropboxKeychain {
    static let service = "CZ.commander Dropbox"

    static func save(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Client

/// Thread-safe Dropbox API client. One shared instance; tokens refresh automatically.
public final class DropboxClient: @unchecked Sendable {
    public static let shared = DropboxClient()

    private let lock = NSLock()
    private var accessToken: String?
    private var accessExpiry: Date = .distantPast
    private var refreshToken: String?
    public private(set) var accountName: String?
    public private(set) var accountEmail: String?
    let session: URLSession

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
        refreshToken = DropboxKeychain.load(account: "refresh_token")
        accountName = DropboxKeychain.load(account: "account_name")
        accountEmail = DropboxKeychain.load(account: "account_email")
    }

    public var isSignedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return refreshToken != nil
    }

    public func signOut() {
        let token = currentAccessTokenIfValid()
        lock.lock()
        refreshToken = nil
        accessToken = nil
        accountName = nil
        accountEmail = nil
        lock.unlock()
        DropboxKeychain.delete(account: "refresh_token")
        DropboxKeychain.delete(account: "account_name")
        DropboxKeychain.delete(account: "account_email")
        if let token {
            var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!)
            req.httpMethod = "POST"
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            session.dataTask(with: req).resume()
        }
    }

    private func currentAccessTokenIfValid() -> String? {
        lock.lock(); defer { lock.unlock() }
        return accessExpiry > Date() ? accessToken : nil
    }

    // MARK: Sign in (OAuth 2 code flow with PKCE and a loopback redirect)

    public struct PKCE {
        public let verifier: String
        public let challenge: String
        public let state: String

        public init() {
            func random(_ n: Int) -> String {
                var bytes = [UInt8](repeating: 0, count: n)
                _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
                return Data(bytes).base64URL
            }
            verifier = random(48)
            challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            state = random(16)
        }
    }

    public static func authorizeURL(pkce: PKCE) -> URL {
        var c = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: DropboxConfig.appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "redirect_uri", value: DropboxConfig.redirectURI),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "scope", value: DropboxConfig.scopes.joined(separator: " ")),
        ]
        return c.url!
    }

    /// Opens nothing itself: `openURL` shows the Dropbox page in the user's browser. Waits for
    /// the redirect on localhost, exchanges the code and stores the refresh token.
    public func signIn(openURL: @Sendable (URL) -> Void) async throws {
        let pkce = PKCE()
        let receiver = DropboxRedirectReceiver(expectedState: pkce.state)
        try receiver.start()
        defer { receiver.stop() }
        openURL(Self.authorizeURL(pkce: pkce))
        let code = try await receiver.waitForCode(timeout: 300)

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: DropboxConfig.appKey),
            URLQueryItem(name: "code_verifier", value: pkce.verifier),
            URLQueryItem(name: "redirect_uri", value: DropboxConfig.redirectURI),
        ]
        let json = try await tokenRequest(form)
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw DropboxError("Dropbox did not return a token.")
        }
        let expiry = Date().addingTimeInterval(((json["expires_in"] as? NSNumber)?.doubleValue ?? 14400) - 120)
        lock.withLock {
            accessToken = access
            refreshToken = refresh
            accessExpiry = expiry
        }
        DropboxKeychain.save(refresh, account: "refresh_token")
        try? await loadAccount()
    }

    func loadAccount() async throws {
        let json = try await rpc("users/get_current_account", nil)
        let name = (json["name"] as? [String: Any])?["display_name"] as? String
        let email = json["email"] as? String
        lock.withLock { accountName = name; accountEmail = email }
        if let name { DropboxKeychain.save(name, account: "account_name") }
        if let email { DropboxKeychain.save(email, account: "account_email") }
    }

    private func tokenRequest(_ form: URLComponents) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            throw DropboxError((json["error_description"] as? String) ?? "Dropbox sign-in failed (\(status)).", status: status)
        }
        return json
    }

    /// A valid access token, refreshed when it is about to expire.
    public func validAccessToken() async throws -> String {
        if let t = currentAccessTokenIfValid() { return t }
        let refresh = lock.withLock { refreshToken }
        guard let refresh else { throw DropboxError("Not signed in to Dropbox.", status: 401) }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "client_id", value: DropboxConfig.appKey),
        ]
        let json: [String: Any]
        do {
            json = try await tokenRequest(form)
        } catch let e as DropboxError where e.status == 400 || e.status == 401 {
            signOut()  // the refresh token was revoked: sign in again
            throw DropboxError("Dropbox sign-in expired. Sign in again.", status: 401)
        }
        guard let access = json["access_token"] as? String else { throw DropboxError("Dropbox did not return a token.") }
        let expiry = Date().addingTimeInterval(((json["expires_in"] as? NSNumber)?.doubleValue ?? 14400) - 120)
        lock.withLock {
            accessToken = access
            accessExpiry = expiry
        }
        return access
    }

    // MARK: RPC

    /// POST to api.dropboxapi.com/2/<endpoint> with a JSON body; retries rate limits.
    public func rpc(_ endpoint: String, _ body: [String: Any]?) async throws -> [String: Any] {
        for attempt in 0..<5 {
            let token = try await validAccessToken()
            var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/" + endpoint)!)
            req.httpMethod = "POST"
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 {
                if data.isEmpty { return [:] }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
            if status == 429 || status >= 500, attempt < 4 {
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(1 << attempt)
                try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
                continue
            }
            if status == 401 { lock.withLock { accessExpiry = .distantPast } }
            throw Self.error(from: data, status: status)
        }
        throw DropboxError("Dropbox is busy, try again later.", status: 429)
    }

    static func error(from data: Data, status: Int) -> DropboxError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let summary = (json?["error_summary"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
        return DropboxError(friendly(summary, status: status), status: status)
    }

    static func friendly(_ summary: String, status: Int) -> String {
        if summary.contains("not_found") { return "Not found in Dropbox (\(summary))." }
        if summary.contains("insufficient_space") { return "Not enough space in this Dropbox." }
        if summary.contains("no_write_permission") { return "You can only view this folder." }
        if summary.contains("conflict") { return "Something with this name already exists (\(summary))." }
        if summary.contains("missing_scope") { return "The Dropbox app lacks a permission (\(summary))." }
        if status == 401 { return "Dropbox sign-in expired. Sign in again." }
        return "Dropbox: " + summary
    }

    // MARK: Listing

    public func list(_ location: DropboxLocation) async throws -> [DropboxEntry] {
        switch location {
        case .sharedWithMe:
            return try await listSharedWithMe()
        case .link(let url, let path):
            return try await listFolder(body: ["path": path, "shared_link": ["url": url]], parent: location)
        case .own, .namespace:
            return try await listFolder(body: ["path": location.apiPath ?? "", "limit": 2000], parent: location)
        }
    }

    private func listFolder(body: [String: Any], parent: DropboxLocation) async throws -> [DropboxEntry] {
        var out: [DropboxEntry] = []
        var json = try await rpc("files/list_folder", body)
        while true {
            for case let e as [String: Any] in (json["entries"] as? [Any]) ?? [] {
                if let entry = DropboxEntry.from(json: e, in: parent) { out.append(entry) }
            }
            guard (json["has_more"] as? Bool) == true, let cursor = json["cursor"] as? String else { break }
            json = try await rpc("files/list_folder/continue", ["cursor": cursor])
        }
        return out
    }

    /// Every shared folder you are a member of, added to your Dropbox or not.
    private func listSharedWithMe() async throws -> [DropboxEntry] {
        var out: [DropboxEntry] = []
        var json = try await rpc("sharing/list_folders", ["limit": 1000])
        var mountable = try? await rpc("sharing/list_mountable_folders", ["limit": 1000])
        while true {
            for page in [json, mountable ?? [:]] {
                for case let e as [String: Any] in (page["entries"] as? [Any]) ?? [] {
                    guard let id = e["shared_folder_id"] as? String, let name = e["name"] as? String else { continue }
                    if out.contains(where: { if case .namespace(let x, _) = $0.location { return x == id }; return false }) { continue }
                    let date = (e["time_invited"] as? String).flatMap { DropboxEntry.dateParser.date(from: $0) }
                    out.append(DropboxEntry(name: name, isFolder: true, size: 0, modified: date, location: .namespace(id: id, path: "")))
                }
            }
            var more = false
            if let c = json["cursor"] as? String {
                json = try await rpc("sharing/list_folders/continue", ["cursor": c]); more = true
            } else { json = [:] }
            if let c = mountable?["cursor"] as? String {
                mountable = try? await rpc("sharing/list_mountable_folders/continue", ["cursor": c]); more = true
            } else { mountable = nil }
            if !more { break }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolves a pasted shared link to its folder (or file) name.
    public func linkInfo(_ url: String) async throws -> (name: String, isFolder: Bool) {
        let json = try await rpc("sharing/get_shared_link_metadata", ["url": url])
        return ((json["name"] as? String) ?? "Shared link", (json[".tag"] as? String) == "folder")
    }

    // MARK: Changes

    public func createFolder(_ location: DropboxLocation) async throws {
        guard let path = location.apiPath else { throw DropboxError("This place is read-only.") }
        _ = try await rpc("files/create_folder_v2", ["path": path, "autorename": false])
    }

    /// Moves to Dropbox's deleted files (restorable on dropbox.com).
    public func delete(_ location: DropboxLocation) async throws {
        guard let path = location.apiPath else { throw DropboxError("This place is read-only.") }
        _ = try await rpc("files/delete_v2", ["path": path])
    }

    public func move(_ from: DropboxLocation, to: DropboxLocation) async throws {
        guard let a = from.apiPath, let b = to.apiPath else { throw DropboxError("This place is read-only.") }
        _ = try await rpc("files/move_v2", ["from_path": a, "to_path": b, "autorename": false])
    }

    public func copy(_ from: DropboxLocation, to: DropboxLocation) async throws {
        guard let a = from.apiPath, let b = to.apiPath else { throw DropboxError("This place is read-only.") }
        _ = try await rpc("files/copy_v2", ["from_path": a, "to_path": b, "autorename": true])
    }

    public func exists(_ location: DropboxLocation) async -> Bool {
        guard let path = location.apiPath, !path.isEmpty else { return true }
        return (try? await rpc("files/get_metadata", ["path": path])) != nil
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback redirect receiver

/// Tiny HTTP listener on localhost:53682 that catches Dropbox's redirect with the code.
final class DropboxRedirectReceiver: @unchecked Sendable {
    private let expectedState: String
    private var listener: NWListener?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(expectedState: String) { self.expectedState = expectedState }

    func start() throws {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: DropboxConfig.redirectPort) else { return }
        let l: NWListener
        do {
            l = try NWListener(using: params, on: port)
        } catch {
            throw DropboxError("Port \(DropboxConfig.redirectPort) is busy; close other sign-in windows and try again.")
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(with: result)
                return
            }
            continuation = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(DropboxError("Dropbox sign-in timed out.")))
            }
        }
    }

    private func finish(_ r: Result<String, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let outcome = Self.parse(request: request, expectedState: self.expectedState)
            let ok: Bool
            let page: String
            switch outcome {
            case .code:
                ok = true
                page = "CZ.commander is now connected to Dropbox. You can close this tab."
            case .error(let msg):
                ok = false
                page = "Dropbox sign-in failed: " + msg
            case .ignore:
                conn.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let html = "<!doctype html><meta charset=utf-8><title>CZ.commander</title><body style=\"font:16px -apple-system;padding:40px\">"
                + (ok ? "&#10003; " : "") + page + "</body>"
            let body = Data(html.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            switch outcome {
            case .code(let c): self.finish(.success(c))
            case .error(let m): self.finish(.failure(DropboxError("Dropbox sign-in failed: " + m)))
            case .ignore: break
            }
        }
    }

    enum Outcome: Equatable {
        case code(String)
        case error(String)
        case ignore
    }

    /// Reads "GET /czcommander-dropbox?code=…&state=… HTTP/1.1".
    static func parse(request: String, expectedState: String) -> Outcome {
        guard let first = request.split(separator: "\r\n", maxSplits: 1).first ?? request.split(separator: "\n").first else { return .ignore }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: "http://localhost" + parts[1]),
              comps.path == DropboxConfig.redirectPath else { return .ignore }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let err = q["error"] { return .error(q["error_description"] ?? err) }
        guard q["state"] == expectedState else { return .error("state mismatch") }
        guard let code = q["code"], !code.isEmpty else { return .error("no code") }
        return .code(code)
    }
}
