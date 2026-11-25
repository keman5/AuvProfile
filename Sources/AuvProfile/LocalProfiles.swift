import CryptoKit
import Foundation
import Security

struct ProfileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Client: String, CaseIterable, Identifiable, Codable {
    case codex = "ChatGPT"
    case claude = "Claude"
    case antigravity = "Antigravity"
    case web = "网页账号"

    var id: String { rawValue }
    var storageKey: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .antigravity: "antigravity"
        case .web: "web"
        }
    }
    var icon: String {
        switch self {
        case .codex: "bubble.left.and.bubble.right"
        case .claude: "sparkle"
        case .antigravity: "triangle"
        case .web: "globe"
        }
    }
}

enum ProfileKind: String, Codable {
    case unified
    case browser
}

enum AuthMode: String, Codable, CaseIterable, Identifiable {
    case oauth = "OAuth / 客户端登录"
    case apiKey = "API Key / Token"

    var id: String { rawValue }
}

struct OAuthAccountOption: Identifiable, Hashable {
    let id: String
    let label: String
}

struct Profile: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var client: Client = .codex
    var kind: ProfileKind = .unified
    var name: String
    var detail: String = ""
    var active: Bool = false

    // 1. 登录账号 (Login Account)
    var authMode: AuthMode = .oauth
    var oauthAccountKey: String? = nil
    var oauthAccountLabel: String? = nil
    var apiKey: String = ""

    // 2. 模型服务商 (Model Provider)
    var providerId: String = "openai"
    var providerName: String = "OpenAI"
    var baseUrl: String = ""
    var wireApi: String = "responses"
    var envKey: String = ""
    var bearerToken: String = ""
    var requiresOpenaiAuth: Bool = false
    var model: String = ""
    var cloudProject: String = ""

    // 3. CLI 启动配置 (CLI Launch & Config File)
    var workingDirectoryPath: String = ""
    var extraCLIArgs: String = ""
    var configText: String = ""
    var profileDirectoryPath: String? = nil

    // 浏览器 Profile 专用
    var path: URL? = nil
    var argument: String? = nil

    var accountBadge: String {
        switch authMode {
        case .oauth:
            if let label = oauthAccountLabel, !label.isEmpty {
                return label
            }
            switch client {
            case .codex: return "ChatGPT OAuth"
            case .claude: return "Claude OAuth"
            case .antigravity: return "Google OAuth"
            case .web: return detail
            }
        case .apiKey:
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "API Key (未填写)" }
            return "API Key · " + String(trimmed.suffix(4))
        }
    }

    var providerBadge: String {
        switch client {
        case .codex:
            if providerId == "openai" || providerId.isEmpty {
                return "OpenAI 官方"
            }
            if !providerName.isEmpty { return providerName }
            if let host = URL(string: baseUrl)?.host() { return host }
            return providerId
        case .claude:
            if let host = URL(string: baseUrl)?.host(), !baseUrl.isEmpty {
                return host
            }
            return "Anthropic 官方"
        case .antigravity:
            if let host = URL(string: baseUrl)?.host(), !baseUrl.isEmpty {
                return host
            }
            if !cloudProject.isEmpty { return "Vertex · \(cloudProject)" }
            return "Google Gemini"
        case .web:
            return detail
        }
    }

    var cliBadge: String {
        var parts: [String] = []
        if !model.isEmpty {
            parts.append(model)
        }
        if !extraCLIArgs.isEmpty {
            parts.append(extraCLIArgs)
        }
        if parts.isEmpty {
            switch client {
            case .codex: return "config.toml"
            case .claude: return "settings.json"
            case .antigravity: return "settings.json"
            case .web: return argument ?? "Default"
            }
        }
        return parts.joined(separator: " · ")
    }
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
        if let base = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host() != nil, url.user() == nil, url.password() == nil else {
                throw ProfileError("Base URL 需要是有效的 HTTP 或 HTTPS 地址，且地址中不能包含登录凭据。")
            }
            copy.baseUrl = base
        } else {
            copy.baseUrl = nil
        }
        return copy
    }
}

struct ManagedAccount: Codable, Identifiable, Equatable {
    var id = ""
    var client: Client
    var name: String
    var apiKey: String
    var baseUrl: String?
    var model: String?
    var project: String?

    func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.baseUrl = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.project = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.baseUrl?.isEmpty == true { copy.baseUrl = nil }
        if copy.model?.isEmpty == true { copy.model = nil }
        if copy.project?.isEmpty == true { copy.project = nil }

        guard !copy.apiKey.isEmpty,
              !copy.apiKey.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw ProfileError("请输入有效的 API Key 或 Auth Token（不能包含空格或换行）。")
        }
        if let base = copy.baseUrl {
            guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host() != nil, url.user() == nil, url.password() == nil else {
                throw ProfileError("Base URL 需要是有效的 HTTP 或 HTTPS 地址，且不能包含登录凭据。")
            }
        }
        if copy.id.isEmpty {
            let fingerprint = [copy.client.storageKey, copy.apiKey, copy.baseUrl ?? "", copy.project ?? ""].joined(separator: "|")
            copy.id = "\(copy.client.storageKey)-" + String(hash(fingerprint).prefix(12))
        }
        if copy.name.isEmpty {
            let host = copy.baseUrl.flatMap { URL(string: $0)?.host() }
            let suffix = String(copy.apiKey.suffix(4))
            copy.name = (host ?? "\(copy.client.rawValue) API") + " · " + suffix
        }
        return copy
    }

    var summaryDetail: String {
        var parts: [String] = []
        if let host = baseUrl.flatMap({ URL(string: $0)?.host() }) {
            parts.append(host)
        } else {
            parts.append(client == .claude ? "Anthropic API" : "Gemini / Google API")
        }
        if let model, !model.isEmpty { parts.append(model) }
        if let project, !project.isEmpty { parts.append(project) }
        parts.append("钥匙串")
        return parts.joined(separator: " · ")
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
            throw ProfileError("找不到配置解析组件。请通过 ./scripts/build.sh 构建应用。")
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
            throw ProfileError("配置无法解析，请检查 TOML 语法是否正确。")
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

    static func apiKeyData(_ rawKey: String) throws -> Data {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw ProfileError("请输入有效的 OpenAI API Key（不能包含空格或换行）。")
        }
        return try JSONSerialization.data(
            withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": trimmed],
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}

func restoreCodexAuth(_ target: Data, to file: URL, saveCurrent: (CodexAccount, Data) throws -> Void) throws {
    guard let incoming = CodexAccount(target) else { throw ProfileError("钥匙串里的账号格式无法识别。") }
    let original = try PrivateFiles.read(file)
    if let original {
        guard let account = CodexAccount(original) else {
            throw ProfileError("当前 auth.json 无法识别，已保留文件。请先通过客户端处理当前登录。")
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
