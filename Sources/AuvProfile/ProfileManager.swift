import AppKit
import Foundation
import SwiftUI

@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var profiles: [Client: [Profile]] = [:]
    @Published private(set) var oauthAccounts: [OAuthAccountOption] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var discoveryIssue: String?
    @Published private(set) var workingDirectory: URL
    @Published var issue: String?

    private let home: URL
    private let support: URL
    private let codexRoot: URL
    private let launcher: ClientLauncher
    private let helper = CodexConfigHelper()
    private let vault = AccountVault()
    private let secretVault = AccountVault(service: "com.keman5.AuvProfile.profile-secret")
    private let preferences = UserDefaults.standard
    private var lastAuth: Data?
    private var browserCache: [String: (mtime: Date?, profiles: [Profile])] = [:]
    private var refreshTimer: Timer?
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    private var activeObserver: NSObjectProtocol?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        support = home.appending(path: "Library/Application Support/AuvProfile")
        codexRoot = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appending(path: ".codex")
        launcher = ClientLauncher(support: support, home: home)
        if let savedDir = preferences.string(forKey: "cli.workingDirectory"),
           (try? URL(fileURLWithPath: savedDir).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            workingDirectory = URL(fileURLWithPath: savedDir)
        } else {
            workingDirectory = home
        }
        loadOrBootstrapProfiles()
        setupWatchers()
        refresh()
    }

    deinit {
        refreshTimer?.invalidate()
        for watcher in directoryWatchers { watcher.cancel() }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    var codexConfigFile: URL { codexRoot.appending(path: "config.toml") }
    private var codexAuthFile: URL { codexRoot.appending(path: "auth.json") }
    private var claudeRoot: URL { home.appending(path: ".claude") }
    private var geminiRoot: URL { home.appending(path: ".gemini") }
    private var antigravityRoot: URL { home.appending(path: ".gemini/antigravity") }
    private var unifiedStoreFile: URL { support.appending(path: "unified-profiles-v2.json") }

    private func setupWatchers() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        for dir in [codexRoot, claudeRoot, geminiRoot, antigravityRoot] {
            watchDirectory(dir)
        }
    }

    private func watchDirectory(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatchers.append(source)
    }

    // MARK: - Storage & Initial Discovery

    private func loadOrBootstrapProfiles() {
        var loaded: [Client: [Profile]] = [:]
        if let data = try? PrivateFiles.read(unifiedStoreFile),
           let decoded = try? JSONDecoder().decode([String: [Profile]].self, from: data) {
            for client in [Client.codex, .claude, .antigravity] {
                if let items = decoded[client.storageKey], !items.isEmpty {
                    loaded[client] = items.map(hydrateSecrets)
                }
            }
        }

        syncCodexOAuthFromDisk()

        if loaded[.codex]?.isEmpty != false {
            loaded[.codex] = bootstrapCodexProfiles()
        }
        if loaded[.claude]?.isEmpty != false {
            loaded[.claude] = bootstrapClaudeProfiles()
        }
        if loaded[.antigravity]?.isEmpty != false {
            loaded[.antigravity] = bootstrapAntigravityProfiles()
        }

        for client in [Client.codex, .claude, .antigravity] {
            var list = loaded[client] ?? []
            if !list.contains(where: \.active), !list.isEmpty {
                list[0].active = true
            }
            loaded[client] = list
        }

        profiles = loaded
        persistUnifiedProfiles()
    }

    private func hydrateSecrets(_ profile: Profile) -> Profile {
        var copy = profile
        if let keyData = try? secretVault.read("api-" + profile.id),
           let key = String(data: keyData, encoding: .utf8) {
            copy.apiKey = key
        }
        if let tokenData = try? secretVault.read("bearer-" + profile.id),
           let token = String(data: tokenData, encoding: .utf8) {
            copy.bearerToken = token
        }
        return copy
    }

    private func persistSecrets(for profile: Profile) {
        let apiId = "api-" + profile.id
        if profile.apiKey.isEmpty {
            try? secretVault.remove(apiId)
        } else if let data = profile.apiKey.data(using: .utf8) {
            try? secretVault.save(data, id: apiId)
        }

        let bearerId = "bearer-" + profile.id
        if profile.bearerToken.isEmpty {
            try? secretVault.remove(bearerId)
        } else if let data = profile.bearerToken.data(using: .utf8) {
            try? secretVault.save(data, id: bearerId)
        }
    }

    private func removeSecrets(for profileId: String) {
        try? secretVault.remove("api-" + profileId)
        try? secretVault.remove("bearer-" + profileId)
    }

    private func persistUnifiedProfiles() {
        var serializable: [String: [Profile]] = [:]
        for client in [Client.codex, .claude, .antigravity] {
            let list = (profiles[client] ?? []).map { item -> Profile in
                persistSecrets(for: item)
                var redacted = item
                redacted.apiKey = ""
                redacted.bearerToken = ""
                return redacted
            }
            serializable[client.storageKey] = list
        }
        guard let data = try? JSONEncoder().encode(serializable) else { return }
        let existing = try? PrivateFiles.read(unifiedStoreFile)
        try? PrivateFiles.replace(unifiedStoreFile, expected: existing, with: data)
    }

    private func syncCodexOAuthFromDisk() {
        var saved = preferences.dictionary(forKey: "codex.accounts") as? [String: String] ?? [:]
        if let data = try? PrivateFiles.read(codexAuthFile), let account = CodexAccount(data) {
            if data != lastAuth || saved[account.key] == nil {
                try? vault.save(data, id: account.key)
                if saved[account.key] == nil {
                    saved[account.key] = account.label
                    preferences.set(saved, forKey: "codex.accounts")
                }
                lastAuth = data
            }
        }
        oauthAccounts = saved
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
            .map { OAuthAccountOption(id: $0.key, label: $0.value) }
    }

    private func bootstrapCodexProfiles() -> [Profile] {
        let rawConfig = (try? PrivateFiles.read(codexConfigFile)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let parsed = try? helper.call("inspect", source: rawConfig)
        let activeProviderId = parsed?.active ?? "openai"

        var currentOAuthKey: String?
        var currentOAuthLabel: String?
        var currentApiKey = ""
        var currentAuthMode: AuthMode = .oauth

        if let authData = try? PrivateFiles.read(codexAuthFile), let account = CodexAccount(authData) {
            if account.key.hasPrefix("api-"),
               let root = decodedObject(authData),
               let rawKey = root["OPENAI_API_KEY"] as? String {
                currentAuthMode = .apiKey
                currentApiKey = rawKey
            } else {
                currentAuthMode = .oauth
                currentOAuthKey = account.key
                currentOAuthLabel = account.label
            }
        } else if let firstOAuth = oauthAccounts.first {
            currentOAuthKey = firstOAuth.id
            currentOAuthLabel = firstOAuth.label
        }

        var results: [Profile] = []
        let activeProvider = parsed?.providers.first { $0.id == activeProviderId }

        let mainProfile = Profile(
            id: UUID().uuidString,
            client: .codex,
            kind: .unified,
            name: "默认 ChatGPT 配置",
            active: true,
            authMode: currentAuthMode,
            oauthAccountKey: currentOAuthKey,
            oauthAccountLabel: currentOAuthLabel,
            apiKey: currentApiKey,
            providerId: activeProviderId,
            providerName: activeProvider?.name ?? (activeProviderId == "openai" ? "OpenAI" : activeProviderId),
            baseUrl: activeProvider?.baseUrl ?? "",
            wireApi: activeProvider?.wireApi ?? "responses",
            envKey: activeProvider?.envKey ?? "",
            bearerToken: activeProvider?.experimentalBearerToken ?? "",
            requiresOpenaiAuth: activeProvider?.requiresOpenaiAuth ?? false,
            configText: rawConfig.isEmpty ? "model_provider = \"openai\"\n" : rawConfig
        )
        results.append(mainProfile)

        // Also turn any other configured providers into ready-to-switch profiles
        if let providers = parsed?.providers {
            for p in providers where p.id != activeProviderId {
                let extra = Profile(
                    id: UUID().uuidString,
                    client: .codex,
                    kind: .unified,
                    name: p.name ?? p.id,
                    active: false,
                    authMode: currentAuthMode,
                    oauthAccountKey: currentOAuthKey,
                    oauthAccountLabel: currentOAuthLabel,
                    apiKey: currentApiKey,
                    providerId: p.id,
                    providerName: p.name ?? p.id,
                    baseUrl: p.baseUrl ?? "",
                    wireApi: p.wireApi ?? "responses",
                    envKey: p.envKey ?? "",
                    bearerToken: p.experimentalBearerToken ?? "",
                    requiresOpenaiAuth: p.requiresOpenaiAuth ?? false,
                    configText: rawConfig
                )
                results.append(extra)
            }
        }
        return results
    }

    private func bootstrapClaudeProfiles() -> [Profile] {
        let settingsURL = claudeRoot.appending(path: "settings.json")
        let rawText = (try? PrivateFiles.read(settingsURL)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\n  \"env\": {}\n}\n"
        let root = rawText.data(using: .utf8).flatMap(decodedObject) ?? [:]
        let env = (root["env"] as? [String: Any]) ?? [:]
        let apiKey = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String) ?? ""
        let baseUrl = (env["ANTHROPIC_BASE_URL"] as? String) ?? ""
        let model = (env["ANTHROPIC_MODEL"] as? String) ?? ""

        let defaultProfile = Profile(
            id: UUID().uuidString,
            client: .claude,
            kind: .unified,
            name: "默认 Claude 配置",
            active: true,
            authMode: apiKey.isEmpty ? .oauth : .apiKey,
            oauthAccountLabel: "Claude Code 登录",
            apiKey: apiKey,
            providerId: "anthropic",
            providerName: baseUrl.isEmpty ? "Anthropic 官方" : (URL(string: baseUrl)?.host() ?? "自定义服务商"),
            baseUrl: baseUrl,
            model: model,
            configText: rawText,
            profileDirectoryPath: claudeRoot.path
        )
        return [defaultProfile]
    }

    private func bootstrapAntigravityProfiles() -> [Profile] {
        let agySettingsURL = antigravityRoot.appending(path: "settings.json")
        let globalSettingsURL = geminiRoot.appending(path: "settings.json")
        let targetURL = FileManager.default.fileExists(atPath: agySettingsURL.path) ? agySettingsURL : globalSettingsURL
        let rawText = (try? PrivateFiles.read(targetURL)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\n  \"env\": {}\n}\n"
        let root = rawText.data(using: .utf8).flatMap(decodedObject) ?? [:]
        let env = (root["env"] as? [String: Any]) ?? [:]
        let apiKey = (env["GEMINI_API_KEY"] as? String) ?? (env["GOOGLE_API_KEY"] as? String) ?? ""
        let baseUrl = (env["GOOGLE_GEMINI_BASE_URL"] as? String) ?? ""
        let model = (env["GEMINI_MODEL"] as? String) ?? ""
        let project = (env["GOOGLE_CLOUD_PROJECT"] as? String) ?? ""

        let defaultProfile = Profile(
            id: UUID().uuidString,
            client: .antigravity,
            kind: .unified,
            name: "默认 Antigravity 配置",
            active: true,
            authMode: apiKey.isEmpty ? .oauth : .apiKey,
            oauthAccountLabel: "Google 账号登录",
            apiKey: apiKey,
            providerId: "google",
            providerName: baseUrl.isEmpty ? "Google Gemini" : (URL(string: baseUrl)?.host() ?? "自定义端点"),
            baseUrl: baseUrl,
            model: model,
            cloudProject: project,
            configText: rawText,
            profileDirectoryPath: antigravityRoot.path
        )
        return [defaultProfile]
    }

    func refresh() {
        guard !busy else { return }
        syncCodexOAuthFromDisk()
        var snapshot = profiles
        snapshot[.web] = browserProfiles()
        if profiles != snapshot {
            profiles = snapshot
        }
    }

    // MARK: - Unified Profile CRUD & Duplication

    func newProfile(for client: Client) -> Profile {
        let count = (profiles[client] ?? []).count + 1
        let defaultText: String = switch client {
        case .codex:
            (try? PrivateFiles.read(codexConfigFile)).flatMap { String(data: $0, encoding: .utf8) } ?? "model_provider = \"openai\"\n"
        case .claude, .antigravity, .web:
            "{\n  \"env\": {}\n}\n"
        }
        return Profile(
            id: UUID().uuidString,
            client: client,
            kind: .unified,
            name: "\(client.rawValue) 配置 \(count)",
            active: (profiles[client] ?? []).isEmpty,
            authMode: client == .codex ? (oauthAccounts.isEmpty ? .apiKey : .oauth) : .apiKey,
            oauthAccountKey: client == .codex ? oauthAccounts.first?.id : nil,
            oauthAccountLabel: client == .codex ? oauthAccounts.first?.label : nil,
            providerId: client == .codex ? "openai" : (client == .claude ? "anthropic" : "google"),
            providerName: client == .codex ? "OpenAI" : (client == .claude ? "Anthropic 官方" : "Google Gemini"),
            wireApi: "responses",
            configText: defaultText
        )
    }

    func duplicateProfile(_ source: Profile) -> Profile {
        let client = source.client
        var list = profiles[client] ?? []
        let existingNames = Set(list.map(\.name))
        var copyName = "\(source.name) 副本"
        var index = 2
        while existingNames.contains(copyName) {
            copyName = "\(source.name) 副本 \(index)"
            index += 1
        }

        var copy = source
        copy.id = UUID().uuidString
        copy.name = copyName
        copy.active = false
        if copy.profileDirectoryPath != nil {
            copy.profileDirectoryPath = support.appending(path: "Profiles/\(client.storageKey)/\(copy.id)").path
        }

        if let idx = list.firstIndex(where: { $0.id == source.id }) {
            list.insert(copy, at: idx + 1)
        } else {
            list.append(copy)
        }
        profiles[client] = list
        persistUnifiedProfiles()
        status = "已复制配置：\(copy.name)"
        return copy
    }

    func deleteProfile(_ profile: Profile, for client: Client) {
        var list = profiles[client] ?? []
        list.removeAll { $0.id == profile.id }
        removeSecrets(for: profile.id)
        if let dirPath = profile.profileDirectoryPath,
           dirPath.hasPrefix(support.appending(path: "Profiles").path) {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: dirPath), resultingItemURL: nil)
        }
        if list.isEmpty {
            list = [newProfile(for: client)]
        }
        if !list.contains(where: \.active) {
            list[0].active = true
        }
        profiles[client] = list
        persistUnifiedProfiles()
        status = "已删除配置：\(profile.name)"
    }

    func synthesizeConfigText(for profile: Profile) throws -> String {
        switch profile.client {
        case .codex:
            var source = profile.configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "model_provider = \"openai\"\n"
                : profile.configText
            _ = try helper.call("inspect", source: source)
            let pid = profile.providerId.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveProviderId = pid.isEmpty ? "openai" : pid
            if effectiveProviderId != "openai" && effectiveProviderId != "ollama" && effectiveProviderId != "lmstudio" {
                let provider = try Provider(
                    id: effectiveProviderId,
                    name: profile.providerName.isEmpty ? effectiveProviderId : profile.providerName,
                    baseUrl: profile.baseUrl.isEmpty ? nil : profile.baseUrl,
                    envKey: profile.envKey.isEmpty ? nil : profile.envKey,
                    experimentalBearerToken: profile.bearerToken.isEmpty ? nil : profile.bearerToken,
                    wireApi: profile.wireApi.isEmpty ? "responses" : profile.wireApi,
                    requiresOpenaiAuth: profile.requiresOpenaiAuth
                ).validated()
                if let updated = try helper.call("update", source: source, provider: provider).text {
                    source = updated
                }
            }
            if let activated = try helper.call("activate", source: source, id: effectiveProviderId).text {
                source = activated
            }
            return source

        case .claude:
            let baseText = profile.configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : profile.configText
            guard let data = baseText.data(using: .utf8), var root = decodedObject(data) else {
                throw ProfileError("下方 JSON 配置文件语法无效，请检查括号与引号。")
            }
            var env = (root["env"] as? [String: Any]) ?? [:]
            let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if profile.authMode == .apiKey && !key.isEmpty {
                env["ANTHROPIC_AUTH_TOKEN"] = key
                env["ANTHROPIC_API_KEY"] = key
            } else if profile.authMode == .oauth {
                env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
                env.removeValue(forKey: "ANTHROPIC_API_KEY")
            }
            let base = profile.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty {
                _ = try Provider(id: "claude", baseUrl: base).validated()
                env["ANTHROPIC_BASE_URL"] = base
            } else {
                env.removeValue(forKey: "ANTHROPIC_BASE_URL")
            }
            let mdl = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mdl.isEmpty {
                env["ANTHROPIC_MODEL"] = mdl
            } else {
                env.removeValue(forKey: "ANTHROPIC_MODEL")
            }
            root["env"] = env
            let pretty = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            return (String(data: pretty, encoding: .utf8) ?? "{}") + "\n"

        case .antigravity:
            let baseText = profile.configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : profile.configText
            guard let data = baseText.data(using: .utf8), var root = decodedObject(data) else {
                throw ProfileError("下方 JSON 配置文件语法无效，请检查括号与引号。")
            }
            var env = (root["env"] as? [String: Any]) ?? [:]
            let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if profile.authMode == .apiKey && !key.isEmpty {
                env["GEMINI_API_KEY"] = key
                env["GOOGLE_API_KEY"] = key
            } else if profile.authMode == .oauth {
                env.removeValue(forKey: "GEMINI_API_KEY")
                env.removeValue(forKey: "GOOGLE_API_KEY")
            }
            let base = profile.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty {
                _ = try Provider(id: "agy", baseUrl: base).validated()
                env["GOOGLE_GEMINI_BASE_URL"] = base
            } else {
                env.removeValue(forKey: "GOOGLE_GEMINI_BASE_URL")
            }
            let mdl = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mdl.isEmpty {
                env["GEMINI_MODEL"] = mdl
            } else {
                env.removeValue(forKey: "GEMINI_MODEL")
            }
            let proj = profile.cloudProject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !proj.isEmpty {
                env["GOOGLE_CLOUD_PROJECT"] = proj
            } else {
                env.removeValue(forKey: "GOOGLE_CLOUD_PROJECT")
            }
            root["env"] = env
            let pretty = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            return (String(data: pretty, encoding: .utf8) ?? "{}") + "\n"

        case .web:
            return profile.configText
        }
    }

    func saveProfile(_ draft: Profile, activate: Bool) async throws -> Profile {
        guard !busy else { throw ProfileError("正在处理另一项操作，请稍后重试。") }
        busy = true
        defer {
            busy = false
            refresh()
        }

        var copy = draft
        copy.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else {
            throw ProfileError("配置名称不能为空。")
        }
        copy.configText = try synthesizeConfigText(for: copy)
        if copy.authMode == .oauth, copy.client == .codex {
            if let key = copy.oauthAccountKey,
               let match = oauthAccounts.first(where: { $0.id == key }) {
                copy.oauthAccountLabel = match.label
            }
        }

        var list = profiles[copy.client] ?? []
        if let idx = list.firstIndex(where: { $0.id == copy.id }) {
            copy.active = list[idx].active
            list[idx] = copy
        } else {
            copy.active = list.isEmpty
            list.append(copy)
        }
        profiles[copy.client] = list
        persistUnifiedProfiles()

        if activate || copy.active {
            try await activateUnifiedProfile(copy)
            status = "已保存并启用配置：\(copy.name)"
        } else {
            status = "已保存配置：\(copy.name)"
        }
        return profiles[copy.client]?.first(where: { $0.id == copy.id }) ?? copy
    }

    // MARK: - Atomic Profile Activation

    func select(_ profile: Profile, for client: Client) {
        operate {
            if profile.kind == .browser {
                try await self.openBrowser(profile)
                self.status = "已打开 \(profile.name)"
            } else {
                try await self.activateUnifiedProfile(profile)
                self.status = "已启用配置：\(profile.name)"
            }
        }
    }

    private func activateUnifiedProfile(_ profile: Profile) async throws {
        var synced = profile
        synced.configText = try synthesizeConfigText(for: synced)

        switch synced.client {
        case .codex:
            try await withCodexStopped {
                // 1. Apply Account (OAuth Snapshot or API Key)
                switch synced.authMode {
                case .apiKey:
                    let trimmedKey = synced.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedKey.isEmpty {
                        let targetAuth = try CodexAccount.apiKeyData(trimmedKey)
                        try restoreCodexAuth(targetAuth, to: self.codexAuthFile) { account, original in
                            try self.vault.save(original, id: account.key)
                            var saved = self.preferences.dictionary(forKey: "codex.accounts") as? [String: String] ?? [:]
                            if saved[account.key] == nil {
                                saved[account.key] = account.label
                                self.preferences.set(saved, forKey: "codex.accounts")
                            }
                        }
                    }
                case .oauth:
                    if let key = synced.oauthAccountKey,
                       let targetAuth = try self.vault.read(key),
                       CodexAccount(targetAuth)?.key == key {
                        try restoreCodexAuth(targetAuth, to: self.codexAuthFile) { account, original in
                            try self.vault.save(original, id: account.key)
                            var saved = self.preferences.dictionary(forKey: "codex.accounts") as? [String: String] ?? [:]
                            if saved[account.key] == nil {
                                saved[account.key] = account.label
                                self.preferences.set(saved, forKey: "codex.accounts")
                            }
                        }
                    }
                }

                // 2. Apply Provider & CLI Config to ~/.codex/config.toml
                let originalConfig = try PrivateFiles.read(self.codexConfigFile)
                try self.applyCodexText(synced.configText, original: originalConfig)
            }

        case .claude:
            let data = Data(synced.configText.utf8)
            // Write to ~/.claude/settings.json so both default `claude` and managed sessions use it
            let defaultSettings = claudeRoot.appending(path: "settings.json")
            try PrivateFiles.replace(defaultSettings, expected: try PrivateFiles.read(defaultSettings), with: data)
            if let customDir = synced.profileDirectoryPath {
                let customURL = URL(fileURLWithPath: customDir)
                try PrivateFiles.directory(customURL)
                let customSettings = customURL.appending(path: "settings.json")
                try PrivateFiles.replace(customSettings, expected: try PrivateFiles.read(customSettings), with: data)
                preferences.set(customURL.path, forKey: "cli.claude")
            } else {
                preferences.set(claudeRoot.path, forKey: "cli.claude")
            }
            if launcher.isCLIRunning(.claude) {
                try await restartCLI(.claude, profile: synced)
            }

        case .antigravity:
            let data = Data(synced.configText.utf8)
            let defaultSettings = antigravityRoot.appending(path: "settings.json")
            try PrivateFiles.replace(defaultSettings, expected: try PrivateFiles.read(defaultSettings), with: data)
            if let customDir = synced.profileDirectoryPath {
                let customURL = URL(fileURLWithPath: customDir)
                try PrivateFiles.directory(customURL)
                let customSettings = customURL.appending(path: "settings.json")
                try PrivateFiles.replace(customSettings, expected: try PrivateFiles.read(customSettings), with: data)
                preferences.set(customURL.path, forKey: "cli.antigravity")
            } else {
                preferences.set(antigravityRoot.path, forKey: "cli.antigravity")
            }
            if launcher.isCLIRunning(.antigravity) {
                try await restartCLI(.antigravity, profile: synced)
            }

        case .web:
            break
        }

        // Mark only this profile as active for its client
        var list = profiles[synced.client] ?? []
        for i in list.indices {
            list[i].active = (list[i].id == synced.id)
            if list[i].id == synced.id {
                list[i].configText = synced.configText
            }
        }
        profiles[synced.client] = list
        persistUnifiedProfiles()
    }

    // MARK: - Import & Login Helpers

    func importConfigOrAuthFile(_ file: URL, into draft: inout Profile) throws {
        guard let data = try PrivateFiles.read(file) else {
            throw ProfileError("无法读取所选文件。")
        }
        if draft.client == .codex {
            if let account = CodexAccount(data) {
                try vault.save(data, id: account.key)
                var saved = preferences.dictionary(forKey: "codex.accounts") as? [String: String] ?? [:]
                saved[account.key] = account.label
                preferences.set(saved, forKey: "codex.accounts")
                syncCodexOAuthFromDisk()
                if account.key.hasPrefix("api-"),
                   let root = decodedObject(data),
                   let rawKey = root["OPENAI_API_KEY"] as? String {
                    draft.authMode = .apiKey
                    draft.apiKey = rawKey
                } else {
                    draft.authMode = .oauth
                    draft.oauthAccountKey = account.key
                    draft.oauthAccountLabel = account.label
                }
                status = "已导入登录凭据：\(account.label)"
                return
            }
            if let text = String(data: data, encoding: .utf8),
               let inspected = try? helper.call("inspect", source: text) {
                draft.configText = text
                if let activeId = inspected.active {
                    draft.providerId = activeId
                    if let p = inspected.providers.first(where: { $0.id == activeId }) {
                        draft.providerName = p.name ?? p.id
                        draft.baseUrl = p.baseUrl ?? ""
                        draft.wireApi = p.wireApi ?? "responses"
                        draft.envKey = p.envKey ?? ""
                        draft.bearerToken = p.experimentalBearerToken ?? ""
                        draft.requiresOpenaiAuth = p.requiresOpenaiAuth ?? false
                    }
                }
                status = "已导入 TOML 配置：\(file.lastPathComponent)"
                return
            }
            throw ProfileError("无法识别该文件，请选择有效的 auth.json 或 config.toml。")
        } else {
            guard let text = String(data: data, encoding: .utf8),
                  let root = decodedObject(data) else {
                throw ProfileError("请选择有效的 JSON 配置文件。")
            }
            draft.configText = text
            let env = (root["env"] as? [String: Any]) ?? root
            if draft.client == .claude {
                if let key = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String), !key.isEmpty {
                    draft.authMode = .apiKey
                    draft.apiKey = key
                }
                if let base = env["ANTHROPIC_BASE_URL"] as? String { draft.baseUrl = base }
                if let mdl = env["ANTHROPIC_MODEL"] as? String { draft.model = mdl }
            } else if draft.client == .antigravity {
                if let key = (env["GEMINI_API_KEY"] as? String) ?? (env["GOOGLE_API_KEY"] as? String), !key.isEmpty {
                    draft.authMode = .apiKey
                    draft.apiKey = key
                }
                if let base = env["GOOGLE_GEMINI_BASE_URL"] as? String { draft.baseUrl = base }
                if let mdl = env["GEMINI_MODEL"] as? String { draft.model = mdl }
                if let proj = env["GOOGLE_CLOUD_PROJECT"] as? String { draft.cloudProject = proj }
            }
            status = "已导入 JSON 配置：\(file.lastPathComponent)"
        }
    }

    func loginClient(_ client: Client) {
        operate {
            switch client {
            case .codex:
                guard let executable = self.launcher.codexExecutable() else {
                    throw ProfileError("未找到 Codex CLI，请先安装或切换到「API Key / Token」模式。")
                }
                _ = try await self.launcher.stopCLI(.codex)
                try await self.launcher.launchCLI(
                    .codex,
                    command: .init(executable: executable, args: ["login"], environment: self.codexEnvironment, workingDirectory: self.workingDirectory)
                )
                self.status = "请在弹出的终端内完成登录，完成后账号会自动同步。"
            case .claude:
                if let executable = self.launcher.claudeExecutable() {
                    _ = try await self.launcher.stopCLI(.claude)
                    try await self.launcher.launchCLI(
                        .claude,
                        command: .init(executable: executable, args: ["login"], environment: ["CLAUDE_CONFIG_DIR": self.claudeRoot.path], workingDirectory: self.workingDirectory)
                    )
                    self.status = "已在终端启动 Claude 登录。"
                } else if let desktop = self.launcher.desktop(.claude) {
                    try await self.launcher.open(desktop)
                    self.status = "已打开 Claude 桌面端进行登录。"
                } else {
                    throw ProfileError("未找到 Claude CLI，请切换到「API Key / Token」直接配置。")
                }
            case .antigravity:
                if let executable = self.launcher.antigravityExecutable() {
                    _ = try await self.launcher.stopCLI(.antigravity)
                    try await self.launcher.launchCLI(
                        .antigravity,
                        command: .init(executable: executable, args: [], environment: [:], workingDirectory: self.workingDirectory)
                    )
                    self.status = "已在终端启动 Antigravity 登录。"
                } else if let desktop = self.launcher.desktop(.antigravity) {
                    try await self.launcher.open(desktop)
                    self.status = "已打开 Antigravity 桌面端进行 Google 账号登录。"
                } else {
                    throw ProfileError("未找到 Antigravity 客户端，请切换到「API Key / Token」直接配置。")
                }
            case .web:
                break
            }
        }
    }

    func openDesktop(_ client: Client) {
        operate {
            try await self.restartDesktop(client)
            self.status = "已打开 \(client.rawValue) 桌面客户端"
        }
    }

    func launchCLI(_ client: Client, profile: Profile? = nil) {
        operate {
            let target = profile ?? self.profiles[client]?.first(where: \.active) ?? self.profiles[client]?.first
            if let target, !target.active {
                try await self.activateUnifiedProfile(target)
            }
            try await self.restartCLI(client, profile: target)
            self.status = "已在终端启动 \(target?.name ?? client.rawValue)"
        }
    }

    func cliCommandString(for profile: Profile) -> String {
        let extra = profile.extraCLIArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraSuffix = extra.isEmpty ? "" : " " + extra
        let dirPrefix: String
        let workDir = profile.workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workDir.isEmpty && workDir != home.path && workDir != "~" {
            dirPrefix = "cd \(shellQuote(workDir)) && "
        } else {
            dirPrefix = ""
        }
        switch profile.client {
        case .codex:
            let mdl = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelArg = mdl.isEmpty ? "" : " --model \(shellQuote(mdl))"
            return "\(dirPrefix)codex\(modelArg)\(extraSuffix)"
        case .claude:
            return "\(dirPrefix)claude\(extraSuffix)"
        case .antigravity:
            return "\(dirPrefix)agy\(extraSuffix)"
        case .web:
            return ""
        }
    }

    func copyCLICommand(for profile: Profile) {
        let cmd = cliCommandString(for: profile)
        guard !cmd.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        status = "已复制启动命令：\(cmd)"
    }

    func revealInFinder(_ profile: Profile) {
        let target: URL = switch profile.client {
        case .codex:
            FileManager.default.fileExists(atPath: codexConfigFile.path) ? codexConfigFile : codexRoot
        case .claude:
            claudeRoot.appending(path: "settings.json")
        case .antigravity:
            antigravityRoot.appending(path: "settings.json")
        case .web:
            profile.path ?? home
        }
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([target.deletingLastPathComponent()])
        }
    }

    func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == home.path { return "~" }
        if path.hasPrefix(home.path + "/") {
            return "~/" + path.dropFirst(home.path.count + 1)
        }
        return path
    }

    func activeSummary(for client: Client) -> String {
        if client == .web {
            let count = profiles[.web, default: []].count
            return count == 0 ? "未发现浏览器" : "\(count) 个浏览器配置"
        }
        if let active = profiles[client, default: []].first(where: \.active) {
            return active.name
        }
        return "未启用"
    }

    // MARK: - Browser Profiles

    private func browserProfiles() -> [Profile] {
        let applicationSupport = home.appending(path: "Library/Application Support")
        let browsers = [
            ("Google Chrome", "Google/Chrome"),
            ("Microsoft Edge", "Microsoft Edge"),
            ("Brave Browser", "BraveSoftware/Brave-Browser"),
            ("Arc", "Arc/User Data"),
        ]
        let lastBrowser = preferences.string(forKey: "last.browser")
        let aliases = preferences.dictionary(forKey: "profile.aliases") as? [String: String] ?? [:]

        return browsers.flatMap { name, directory -> [Profile] in
            guard let app = launcher.application(named: name) else { return [] }
            let stateFile = applicationSupport.appending(path: directory).appending(path: "Local State")
            let mtime = (try? stateFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached = browserCache[name], cached.mtime != nil, cached.mtime == mtime {
                return cached.profiles.map { item in
                    var copy = item
                    if let alias = aliases[item.id], !alias.isEmpty { copy.name = alias }
                    copy.active = (lastBrowser == item.id)
                    return copy
                }
            }
            guard let data = try? PrivateFiles.read(stateFile),
                  let json = decodedObject(data), let profile = json["profile"] as? [String: Any],
                  let known = profile["info_cache"] as? [String: [String: Any]] else { return [] }
            let parsed: [Profile] = known.keys.sorted().compactMap { argument in
                guard argument == "Default" || argument.hasPrefix("Profile "), !argument.contains("/"),
                      (known[argument]?["is_omitted_from_profile_list"] as? Bool) != true else { return nil }
                let nameInBrowser = (known[argument]?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let userName = (known[argument]?["user_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackTitle = (nameInBrowser?.isEmpty == false ? nameInBrowser! : argument)
                let subtitle = (userName?.isEmpty == false) ? "\(name) · \(userName!)" : "\(name) (\(argument))"
                let key = name + "/" + argument
                return Profile(
                    id: key,
                    client: .web,
                    kind: .browser,
                    name: fallbackTitle,
                    detail: subtitle,
                    active: lastBrowser == key,
                    path: app,
                    argument: argument
                )
            }
            browserCache[name] = (mtime: mtime, profiles: parsed)
            return parsed.map { item in
                var copy = item
                if let alias = aliases[item.id], !alias.isEmpty { copy.name = alias }
                copy.active = (lastBrowser == item.id)
                return copy
            }
        }
    }

    func renameBrowserProfile(_ profile: Profile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        var aliases = preferences.dictionary(forKey: "profile.aliases") as? [String: String] ?? [:]
        if trimmed.isEmpty {
            aliases.removeValue(forKey: profile.id)
        } else {
            aliases[profile.id] = trimmed
        }
        preferences.set(aliases, forKey: "profile.aliases")
        refresh()
        status = trimmed.isEmpty ? "已恢复默认名称" : "已重命名为 \(trimmed)"
    }

    func openBrowser(_ profile: Profile, service: WebService = .chatGPT) async throws {
        guard let browser = profile.path, let directory = profile.argument else { throw ProfileError("找不到浏览器 profile。") }
        try await launcher.openBrowser(service.url, in: browser, profile: directory)
        preferences.set(profile.id, forKey: "last.browser")
        refresh()
    }

    func openWeb(_ profile: Profile, service: WebService) {
        operate {
            try await self.openBrowser(profile, service: service)
            self.status = "已通过 \(profile.name) 打开 \(service.rawValue)"
        }
    }

    // MARK: - Process Control

    private func applyCodexText(_ text: String?, original: Data?) throws {
        guard let text else { throw ProfileError("没有生成新配置。") }
        let updated = Data(text.utf8)
        guard updated != original else { return }
        try PrivateFiles.replace(codexConfigFile, expected: original, with: updated)
    }

    private func withCodexStopped(_ operation: () throws -> Void) async throws {
        let desktop = launcher.desktop(.codex)
        let cliWasRunning = try await launcher.stopCLI(.codex)
        var appWasRunning = false
        do {
            if let desktop { appWasRunning = try await launcher.stopDesktop(desktop) }
            try operation()
        } catch {
            if appWasRunning, let desktop { try? await launcher.open(desktop, activate: false) }
            if cliWasRunning { try? await restartCLI(.codex) }
            throw error
        }
        var failures: [String] = []
        if appWasRunning, let desktop {
            do { try await launcher.open(desktop, activate: false) }
            catch { failures.append("ChatGPT / Codex 桌面端") }
        }
        if cliWasRunning {
            do { try await restartCLI(.codex) }
            catch { failures.append("Codex CLI") }
        }
        guard failures.isEmpty else { throw ProfileError("配置已切换，请手动启动 " + failures.joined(separator: "、") + "。") }
    }

    private func restartDesktop(_ client: Client) async throws {
        guard let bundle = launcher.desktop(client) else { throw ProfileError("本机未找到 \(client.rawValue) 桌面端。") }
        _ = try await launcher.stopDesktop(bundle)
        try await launcher.open(bundle)
    }

    private var codexEnvironment: [String: String] { ["CODEX_HOME": codexRoot.path] }

    private func resolveWorkingDirectory(for profile: Profile?) -> URL {
        if let custom = profile?.workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let expanded = custom == "~" ? home.path : (custom.hasPrefix("~/") ? home.path + "/" + custom.dropFirst(2) : custom)
            let url = URL(fileURLWithPath: expanded)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return url
            }
        }
        return workingDirectory
    }

    private func parseExtraArgs(_ raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        return raw.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func restartCLI(_ client: Client, profile: Profile? = nil) async throws {
        let targetDir = resolveWorkingDirectory(for: profile)
        var extra = parseExtraArgs(profile?.extraCLIArgs)
        if let mdl = profile?.model.trimmingCharacters(in: .whitespacesAndNewlines), !mdl.isEmpty, client == .codex {
            if !extra.contains("--model") && !extra.contains("-m") {
                extra = ["--model", mdl] + extra
            }
        }

        let command: ClientLauncher.Command
        switch client {
        case .codex:
            guard let executable = launcher.codexExecutable() else { throw ProfileError("本机未找到 Codex CLI。") }
            command = .init(
                executable: executable,
                args: extra,
                environment: codexEnvironment,
                workingDirectory: targetDir
            )
        case .claude:
            guard let executable = launcher.claudeExecutable() else { throw ProfileError("本机未找到 Claude Code CLI。") }
            let configDir = profile?.profileDirectoryPath ?? claudeRoot.path
            command = .init(
                executable: executable,
                args: extra,
                environment: ["CLAUDE_CONFIG_DIR": configDir],
                workingDirectory: targetDir
            )
        case .antigravity:
            guard let executable = launcher.antigravityExecutable() else { throw ProfileError("本机未找到 Antigravity CLI (agy)。") }
            command = .init(
                executable: executable,
                args: extra,
                environment: [:],
                workingDirectory: targetDir
            )
        case .web:
            return
        }
        _ = try await launcher.stopCLI(client)
        try await launcher.launchCLI(client, command: command)
    }

    private func operate(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        status = ""
        issue = nil
        Task {
            do { try await action() } catch { issue = error.localizedDescription }
            busy = false
            refresh()
        }
    }
}

enum WebService: String, CaseIterable, Identifiable {
    case chatGPT = "ChatGPT"
    case claude = "Claude"
    var id: String { rawValue }
    var url: URL {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/")!
        case .claude: URL(string: "https://claude.ai/")!
        }
    }
}
