import AppKit
import Foundation
import SwiftUI

@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var profiles: [Client: [Profile]] = [:]
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var discoveryIssue: String?
    @Published var issue: String?

    private let home: URL
    private let support: URL
    private let codexRoot: URL
    private let launcher: ClientLauncher
    private let helper = CodexConfigHelper()
    private let vault = AccountVault()
    private let preferences = UserDefaults.standard
    private var lastAuth: Data?
    private var lastConfig: Data?
    private var codexConfig: ConfigResponse?
    private var refreshTimer: Timer?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        support = home.appending(path: "Library/Application Support/AuvProfile")
        codexRoot = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appending(path: ".codex")
        launcher = ClientLauncher(support: support, home: home)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    deinit { refreshTimer?.invalidate() }

    var codexConfigFile: URL { codexRoot.appending(path: "config.toml") }
    private var codexAuthFile: URL { codexRoot.appending(path: "auth.json") }
    private var claudeRoot: URL { home.appending(path: ".claude") }
    private var antigravityRoot: URL { home.appending(path: ".gemini/antigravity") }

    func refresh() {
        guard !busy else { return }
        var snapshot: [Client: [Profile]] = [:]
        do {
            try readCodexConfig()
            snapshot[.codex] = try codexProfiles()
            discoveryIssue = nil
        } catch {
            discoveryIssue = error.localizedDescription
            snapshot[.codex] = codexConfigProfiles()
        }
        snapshot[.claude] = claudeProfiles()
        snapshot[.antigravity] = antigravityProfiles()
        snapshot[.web] = browserProfiles()
        if profiles != snapshot { profiles = snapshot }
    }

    func select(_ profile: Profile, for client: Client) {
        operate {
            switch profile.kind {
            case .codexAccount:
                try await self.activateAccount(profile)
            case .codexProvider:
                let original = try PrivateFiles.read(self.codexConfigFile)
                let current = try self.asText(original)
                let edit = try self.helper.call("activate", source: current, id: profile.argument).text
                try await self.withCodexStopped {
                    try self.applyCodexText(edit, original: original)
                    self.preferences.removeObject(forKey: "cli.codex")
                }
            case .codexOverlay, .codexConfig:
                try await self.restartCLI(.codex, selection: profile)
                self.preferences.set(profile.id, forKey: "cli.codex")
            case .claudeDirectory:
                try await self.restartCLI(.claude, selection: profile)
                self.preferences.set(profile.path?.path, forKey: "cli.claude")
            case .claudeDesktop:
                try await self.restartDesktop(.claude)
            case .antigravity:
                try await self.restartDesktop(.antigravity)
            case .antigravityCLI:
                try await self.restartCLI(.antigravity, selection: profile)
                self.preferences.set(profile.path?.path, forKey: "cli.antigravity")
            case .browser:
                try await self.openBrowser(profile)
            }
            self.status = "已启用 \(profile.name)"
        }
    }

    func launchCLI(_ client: Client) {
        operate {
            try await self.restartCLI(client)
            self.status = "已打开 \(client.rawValue) CLI"
        }
    }

    func loginCodex() {
        operate {
            guard let executable = self.launcher.codexExecutable() else { throw ProfileError("请先安装 Codex CLI。") }
            _ = try await self.launcher.stopCLI(.codex)
            try await self.launcher.launchCLI(.codex, command: .init(executable: executable, args: ["login"], environment: self.codexEnvironment))
            self.status = "完成终端登录后，新账号会出现在列表中。"
        }
    }

    func openDesktop(_ client: Client) {
        operate {
            try await self.restartDesktop(client)
            self.status = "已打开 \(client.rawValue) 客户端"
        }
    }

    func addDirectory(_ directory: URL, for client: Client) {
        var paths = preferences.stringArray(forKey: "directories.\(client.rawValue)") ?? []
        let path = directory.standardizedFileURL.path
        if !paths.contains(path) {
            paths.append(path)
            preferences.set(paths, forKey: "directories.\(client.rawValue)")
        }
        refresh()
    }

    func importCodexAccount(from file: URL) throws {
        guard let data = try PrivateFiles.read(file), let account = CodexAccount(data) else {
            throw ProfileError("请选择 Codex 的 auth.json 文件。")
        }
        var saved = preferences.dictionary(forKey: "codex.accounts") as? [String: String] ?? [:]
        let existing = try vault.read(account.key)
        if saved[account.key] == nil || existing == nil {
            try vault.save(data, id: account.key)
            saved[account.key] = account.label
            preferences.set(saved, forKey: "codex.accounts")
        }
        refresh()
        status = "已导入 Codex 账号"
    }

    func createDirectory(named name: String, for client: Client) throws {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != ".", label != "..", !label.contains("/"),
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ProfileError("请输入有效的配置名称。") }
        let path = support.appending(path: "Profiles/\(client.rawValue)").appending(path: label)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw ProfileError("同名目录已存在。") }
        try PrivateFiles.directory(path)
        try PrivateFiles.replace(path.appending(path: "settings.json"), expected: nil, with: Data("{}\n".utf8))
        addDirectory(path, for: client)
    }

    func provider(_ profile: Profile) -> Provider? {
        codexConfig?.providers.first { $0.id == profile.argument }
    }

    func saveProvider(_ provider: Provider, originalProvider: Provider?) throws {
        let original = try PrivateFiles.read(codexConfigFile)
        let source = try asText(original)
        let validated = try provider.validated()
        let current = try helper.call("inspect", source: source).providers.first { $0.id == validated.id }
        guard current == originalProvider else {
            throw ProfileError(originalProvider == nil ? "该服务商 ID 已存在。" : "服务商已在其他程序中修改，请关闭编辑窗口后重试。")
        }
        let text = try helper.call("update", source: source, provider: validated).text
        try applyCodexText(text, original: original)
        refresh()
        status = "已保存服务商"
    }

    func configFor(_ profile: Profile, client: Client) -> URL? {
        switch profile.kind {
        case .codexConfig: codexConfigFile
        case .codexOverlay: profile.path
        case .claudeDirectory, .antigravityCLI: profile.path?.appending(path: "settings.json")
        case .claudeDesktop: home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
        default: nil
        }
    }

    func readConfig(_ path: URL) throws -> (String, Data?) {
        let contents = try PrivateFiles.read(path)
        return (try asText(contents, defaultValue: path.pathExtension == "json" ? "{}\n" : ""), contents)
    }

    func saveConfig(_ text: String, file: URL, original: Data?) throws {
        if file.pathExtension == "toml" {
            _ = try helper.call("inspect", source: text)
        } else if decodedObject(Data(text.utf8)) == nil {
            throw ProfileError("设置必须是有效的 JSON 对象。")
        }
        try PrivateFiles.replace(file, expected: original, with: Data(text.utf8))
        refresh()
        status = "已保存本地配置"
    }

    func forgetAccount(_ profile: Profile) throws {
        guard profile.kind == .codexAccount, !profile.active, let id = profile.argument else { return }
        try vault.remove(id)
        var saved = preferences.dictionary(forKey: "codex.accounts") as? [String: String] ?? [:]
        saved.removeValue(forKey: id)
        preferences.set(saved, forKey: "codex.accounts")
        refresh()
    }

    private func readCodexConfig() throws {
        let data = try PrivateFiles.read(codexConfigFile)
        if codexConfig == nil || data != lastConfig {
            codexConfig = nil
            codexConfig = try helper.call("inspect", source: asText(data))
            lastConfig = data
        }
    }

    private var fileAuthEnabled: Bool {
        let mode = codexConfig?.authStore
        return codexConfig != nil && (mode == nil || mode == "file")
    }

    private func codexProfiles() throws -> [Profile] {
        var saved = preferences.dictionary(forKey: "codex.accounts") as? [String: String] ?? [:]
        var active: String?
        if fileAuthEnabled, let data = try PrivateFiles.read(codexAuthFile), let account = CodexAccount(data) {
            active = account.key
            if data != lastAuth || saved[account.key] == nil {
                try vault.save(data, id: account.key)
                saved[account.key] = account.label
                preferences.set(saved, forKey: "codex.accounts")
                lastAuth = data
            }
        } else {
            lastAuth = nil
        }
        let accounts = saved.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }.map {
            Profile(id: $0.key, kind: .codexAccount, name: $0.value, detail: "ChatGPT / OpenAI · 钥匙串", argument: $0.key, active: active == $0.key)
        }
        return accounts + codexConfigProfiles()
    }

    private func codexConfigProfiles() -> [Profile] {
        let configChoice = preferences.string(forKey: "cli.codex")
        var entries = [Profile(id: "codex-config", kind: .codexConfig, name: "默认配置", detail: "config.toml", active: configChoice == nil || configChoice == "codex-config")]
        guard let config = codexConfig else { return entries }
        let active = config.active ?? "openai"
        let providers = config.providers.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        if !providers.contains(where: { $0.id == "openai" }) {
            entries.append(.init(id: "provider-openai", kind: .codexProvider, name: "OpenAI", detail: "内置服务商", argument: "openai", active: active == "openai"))
        }
        entries += providers.map {
            .init(id: "provider-" + $0.id, kind: .codexProvider, name: $0.name ?? $0.id,
                  detail: $0.baseUrl.flatMap { URL(string: $0)?.host() } ?? $0.id,
                  argument: $0.id, active: active == $0.id)
        }
        entries += config.profiles.sorted().map {
            .init(id: "profile-v1-" + $0, kind: .codexOverlay, name: $0, detail: "Codex CLI · TOML profile", argument: $0, active: configChoice == "profile-v1-" + $0)
        }
        let suffix = ".config.toml"
        entries += children(codexRoot).filter { $0.lastPathComponent.hasSuffix(suffix) }.map {
            let name = String($0.lastPathComponent.dropLast(suffix.count))
            return .init(id: "profile-v2-" + name, kind: .codexOverlay, name: name, detail: "Codex CLI · 独立 TOML", path: $0, argument: name, active: configChoice == "profile-v2-" + name)
        }
        return entries
    }

    private func claudeProfiles() -> [Profile] {
        let external = importedDirectories(.claude) + children(home).filter { $0.lastPathComponent.hasPrefix(".claude-") }
            + children(claudeRoot.appending(path: "profiles"))
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        let active = preferences.string(forKey: "cli.claude") ?? configured?.path ?? claudeRoot.path
        var rows = directoryProfiles([claudeRoot] + [configured].compactMap { $0 } + external,
                                     kind: .claudeDirectory, active: active, defaultPath: claudeRoot, label: "Claude Code")
        if launcher.desktop(.claude) != nil {
            rows.insert(Profile(id: "claude-desktop", kind: .claudeDesktop, name: "桌面端当前账号", detail: "Claude Desktop · 本地配置"), at: 0)
        }
        return rows
    }

    private func antigravityProfiles() -> [Profile] {
        let active = preferences.string(forKey: "cli.antigravity") ?? antigravityRoot.path
        var rows = directoryProfiles([antigravityRoot] + importedDirectories(.antigravity) + children(antigravityRoot.appending(path: "profiles")),
                                     kind: .antigravityCLI, active: active, defaultPath: antigravityRoot, label: "Antigravity CLI", requiresSettings: true)
        if launcher.desktop(.antigravity) != nil {
            rows.insert(Profile(id: "antigravity-native", kind: .antigravity, name: "桌面端当前账号", detail: "在 Antigravity 内管理 Google 登录"), at: 0)
        }
        return rows
    }

    private func directoryProfiles(_ dirs: [URL], kind: ProfileKind, active: String, defaultPath: URL, label: String, requiresSettings: Bool = false) -> [Profile] {
        var used = Set<String>()
        return dirs.compactMap { url in
            let path = url.standardizedFileURL.path
            let isDefault = path == defaultPath.path
            guard used.insert(path).inserted,
                  isDefault || ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true),
                  isDefault || !requiresSettings || FileManager.default.fileExists(atPath: url.appending(path: "settings.json").path) else { return nil }
            return Profile(id: kind.rawValue + "-" + path, kind: kind, name: isDefault ? "默认配置" : url.lastPathComponent,
                           detail: label + " · " + path.replacingOccurrences(of: home.path + "/", with: "~/"),
                           path: url, active: active == path)
        }
    }

    private func browserProfiles() -> [Profile] {
        let applicationSupport = home.appending(path: "Library/Application Support")
        let browsers = [("Google Chrome", "Google/Chrome"), ("Microsoft Edge", "Microsoft Edge")]
        return browsers.flatMap { name, directory -> [Profile] in
            guard let app = launcher.application(named: name),
                  let data = try? PrivateFiles.read(applicationSupport.appending(path: directory).appending(path: "Local State")),
                  let json = decodedObject(data), let profile = json["profile"] as? [String: Any],
                  let known = profile["info_cache"] as? [String: [String: Any]] else { return [] }
            return known.keys.sorted().compactMap { argument in
                guard argument == "Default" || argument.hasPrefix("Profile "), !argument.contains("/"),
                      (known[argument]?["is_omitted_from_profile_list"] as? Bool) != true else { return nil }
                let nameInBrowser = known[argument]?["name"] as? String ?? argument
                let key = name + "/" + argument
                return Profile(id: key, kind: .browser, name: nameInBrowser, detail: name, path: app, argument: argument,
                               active: preferences.string(forKey: "last.browser") == key)
            }
        }
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

    private func activateAccount(_ profile: Profile) async throws {
        try readCodexConfig()
        guard fileAuthEnabled else { throw ProfileError("当前 Codex 使用文件以外的认证模式。请在客户端内切换登录，或使用文件认证。") }
        guard let id = profile.argument, let target = try vault.read(id), CodexAccount(target)?.key == id else {
            throw ProfileError("钥匙串里找不到该账号。")
        }
        try await withCodexStopped {
            try restoreCodexAuth(target, to: self.codexAuthFile) { account, original in
                try self.vault.save(original, id: account.key)
                var saved = self.preferences.dictionary(forKey: "codex.accounts") as? [String: String] ?? [:]
                saved[account.key] = account.label
                self.preferences.set(saved, forKey: "codex.accounts")
            }
        }
    }

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
            catch { failures.append("Codex 桌面端") }
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

    private func restartCLI(_ client: Client, selection: Profile? = nil) async throws {
        let command: ClientLauncher.Command
        switch client {
        case .codex:
            guard let executable = launcher.codexExecutable() else { throw ProfileError("本机未找到 Codex CLI。") }
            let selected = preferences.string(forKey: "cli.codex")
            let profile = selection ?? codexConfigProfiles().first { $0.id == selected }
            let flag = profile?.path == nil ? "--profile" : "--profile-v2"
            command = .init(executable: executable, args: profile?.argument.map { [flag, $0] } ?? [], environment: codexEnvironment)
        case .claude:
            guard let executable = launcher.executable(["claude"]) else { throw ProfileError("本机未找到 Claude Code。") }
            let path = selection?.path?.path ?? preferences.string(forKey: "cli.claude")
                ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? claudeRoot.path
            command = .init(executable: executable, environment: ["CLAUDE_CONFIG_DIR": path])
        case .antigravity:
            guard let executable = launcher.executable(["agy", "antigravity"]) else { throw ProfileError("本机未找到 Antigravity CLI。") }
            let path = selection?.path?.path ?? preferences.string(forKey: "cli.antigravity") ?? antigravityRoot.path
            command = .init(executable: executable, args: path == antigravityRoot.path ? [] : ["--settings", URL(fileURLWithPath: path).appending(path: "settings.json").path])
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

    private func importedDirectories(_ client: Client) -> [URL] {
        (preferences.stringArray(forKey: "directories.\(client.rawValue)") ?? []).map { URL(fileURLWithPath: $0) }
    }

    private func children(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func asText(_ data: Data?, defaultValue: String = "") throws -> String {
        guard let data else { return defaultValue }
        guard let text = String(data: data, encoding: .utf8) else { throw ProfileError("配置文件需要使用 UTF-8 编码。") }
        return text
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
