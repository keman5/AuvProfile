import CryptoKit
import Foundation
import Security

struct ProfileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Client: String, CaseIterable, Identifiable, Codable {
    case codex = "Codex"
    case claude = "Claude"
    case antigravity = "Antigravity"
    case web = "网页账号"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkle"
        case .antigravity: "triangle"
        case .web: "globe"
        }
    }
}

enum ProfileKind: String, Codable {
    case codexAccount, codexConfig, codexOverlay, codexProvider, claudeDirectory, claudeDesktop, antigravity, antigravityCLI, browser
}

struct Profile: Identifiable, Hashable {
    let id: String
    let kind: ProfileKind
    let name: String
    let detail: String
    var path: URL? = nil
    var argument: String? = nil
    var active = false
}

struct Provider: Codable, Identifiable, Equatable {
    var id = ""
    var name: String?
    var baseUrl: String?
    var envKey: String?
    var experimentalBearerToken: String?
    var wireApi: String?
    var requiresOpenaiAuth: Bool?

    func validated() throws -> Self {
        var copy = self
        copy.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.id.isEmpty, !copy.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError("请输入有效的服务商 ID。")
        }
        if copy.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { copy.name = copy.id }
        if let base = baseUrl, !base.isEmpty {
            guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host() != nil, url.user() == nil, url.password() == nil else {
                throw ProfileError("Base URL 需要是有效的 HTTP 或 HTTPS 地址，且地址中不能包含登录凭据。")
            }
        }
        return copy
    }
}

struct ConfigResponse: Decodable {
    let active: String?
    let authStore: String?
    let providers: [Provider]
    let profiles: [String]
    let text: String?
}

struct CodexConfigHelper {
    func call(_ operation: String, source: String, id: String? = nil, provider: Provider? = nil) throws -> ConfigResponse {
        struct Request: Encodable {
            let operation: String
            let source: String
            let id: String?
            let provider: Provider?
        }

        var helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/auvprofile-config")
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["AUVPROFILE_CONFIG_HELPER"] {
            helper = URL(fileURLWithPath: override)
        }
        #endif
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ProfileError("找不到配置解析组件。请通过 build.sh 构建应用。")
        }
        let request = Request(operation: operation, source: source, id: id, provider: provider)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let input = try encoder.encode(request)
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = helper
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        } catch {
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            throw ProfileError("无法将配置交给解析组件。")
        }
        let result = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProfileError("Codex 配置无法解析，或该服务商已不存在。请检查 config.toml。")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ConfigResponse.self, from: result)
    }
}

struct CodexAccount: Equatable {
    let key: String
    let label: String

    init?(_ data: Data) {
        guard let root = decodedObject(data) else { return nil }
        let mode = root["auth_mode"] as? String
        guard mode == nil || mode == "chatgpt" || mode == "apikey",
              ["agent_identity", "personal_access_token", "bedrock_api_key", "bedrock_access_keys"]
                .allSatisfy({ root[$0] == nil || root[$0] is NSNull }) else { return nil }
        if mode != "apikey", let tokens = root["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            let claims = (tokens["id_token"] as? String).flatMap(jwtClaims) ?? [:]
            let accessClaims = jwtClaims(access) ?? [:]
            let auth = (accessClaims["https://api.openai.com/auth"] as? [String: Any])
                ?? (claims["https://api.openai.com/auth"] as? [String: Any]) ?? [:]
            let workspace = (tokens["account_id"] as? String) ?? (auth["chatgpt_account_id"] as? String)
            let user = (claims["sub"] as? String) ?? (auth["chatgpt_user_id"] as? String)
            let email = (claims["email"] as? String) ?? (accessClaims["email"] as? String)
            let identity = [workspace, user ?? email].compactMap { $0 }.joined(separator: "|")
            guard !identity.isEmpty else { return nil }
            key = "oauth-" + hash(identity)
            label = (email ?? "ChatGPT 登录") + (workspace.map { " · " + String($0.suffix(6)) } ?? "")
        } else if mode != "chatgpt", let apiKey = root["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            key = "api-" + hash(apiKey)
            label = "OpenAI API Key · " + String(key.suffix(6))
        } else {
            return nil
        }
    }
}

func restoreCodexAuth(_ target: Data, to file: URL, saveCurrent: (CodexAccount, Data) throws -> Void) throws {
    guard let incoming = CodexAccount(target) else { throw ProfileError("钥匙串里的账号格式无法识别。") }
    let original = try PrivateFiles.read(file)
    if let original {
        guard let account = CodexAccount(original) else {
            throw ProfileError("当前 auth.json 无法识别，已保留文件。请先通过 Codex 处理当前登录。")
        }
        guard account.key != incoming.key else { return }
        try saveCurrent(account, original)
    }
    try PrivateFiles.replace(file, expected: original, with: target)
}

private func jwtClaims(_ jwt: String) -> [String: Any]? {
    guard let segment = jwt.split(separator: ".").dropFirst().first else { return nil }
    var base = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base += String(repeating: "=", count: (4 - base.utf8.count % 4) % 4)
    return Data(base64Encoded: base).flatMap(decodedObject)
}

func decodedObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct AccountVault {
    var service = "com.keman5.AuvProfile.codex-account"

    func read(_ id: String) throws -> Data? {
        var query = base(id)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return value as? Data
    }

    func save(_ data: Data, id: String) throws {
        if try read(id) == data { return }
        var query = base(id)
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            try check(SecItemAdd(query as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func remove(_ id: String) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ProfileError("无法访问 AuvProfile 的钥匙串项目（\(status)）。") }
    }
}

struct PrivateFiles {
    static func read(_ file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    static func replace(_ file: URL, expected: Data?, with contents: Data) throws {
        let target = file.resolvingSymlinksInPath()
        try directory(target.deletingLastPathComponent())
        let temp = target.deletingLastPathComponent().appending(path: ".auvprofile-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ProfileError("无法创建配置临时文件。")
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.write(contentsOf: contents)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard try read(target) == expected else { throw ProfileError("配置已在其他程序中更新，请刷新后再试。") }
        guard rename(temp.path, target.path) == 0 else { throw ProfileError("无法替换配置文件。") }
    }
}
