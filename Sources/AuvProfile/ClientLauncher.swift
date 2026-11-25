import AppKit
import Darwin
import Foundation

@MainActor
final class ClientLauncher {
    struct Command {
        let executable: URL
        var args: [String] = []
        var environment: [String: String] = [:]
        var workingDirectory: URL? = nil
    }

    private let support: URL
    private let home: URL

    init(support: URL, home: URL) {
        self.support = support
        self.home = home
    }

    var searchPaths: [String] {
        var paths: [String] = [
            home.appending(path: ".local/bin").path,
            home.appending(path: "Library/pnpm/bin").path,
            home.appending(path: "Library/pnpm").path,
            home.appending(path: ".bun/bin").path,
            home.appending(path: ".cargo/bin").path,
            home.appending(path: ".npm-global/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let nvmRoot = home.appending(path: ".nvm/versions/node")
        if let nodes = try? FileManager.default.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil) {
            let sorted = nodes.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            paths.append(contentsOf: sorted.map { $0.appending(path: "bin").path })
        }
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in envPaths where !paths.contains(p) {
            paths.append(p)
        }
        return paths
    }

    func executable(_ names: [String]) -> URL? {
        let search = searchPaths
        return names.lazy.flatMap { name in search.map { URL(fileURLWithPath: $0).appending(path: name) } }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func codexExecutable() -> URL? {
        executable(["codex"])
            ?? desktop(.codex)?.appending(path: "Contents/Resources/codex").existingExecutable
    }

    func claudeExecutable() -> URL? {
        executable(["claude"])
    }

    func antigravityExecutable() -> URL? {
        executable(["agy", "antigravity"])
            ?? desktop(.antigravity)?.appending(path: "Contents/Resources/app/bin/agy").existingExecutable
            ?? desktop(.antigravity)?.appending(path: "Contents/Resources/bin/agy").existingExecutable
    }

    func desktop(_ client: Client) -> URL? {
        let identifiers: [String]
        let names: [String]
        switch client {
        case .codex:
            identifiers = ["com.openai.codex", "com.openai.chat"]
            names = ["Codex", "ChatGPT"]
        case .claude:
            identifiers = ["com.anthropic.claudefordesktop"]
            names = ["Claude"]
        case .antigravity:
            identifiers = ["com.google.antigravity"]
            names = ["Antigravity"]
        case .web:
            return nil
        }
        if let registered = identifiers.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            return registered
        }
        return names.compactMap(application(named:)).first {
            guard let identifier = Bundle(url: $0)?.bundleIdentifier else { return false }
            return identifiers.contains(identifier)
        }
    }

    func application(named name: String) -> URL? {
        [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")]
            .map { $0.appending(path: name + ".app", directoryHint: .isDirectory) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func open(_ bundle: URL, arguments: [String] = [], activate: Bool = true) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        config.arguments = arguments
        _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: config)
    }

    func openBrowser(_ url: URL, in browser: URL, profile: String) async throws {
        guard let executable = Bundle(url: browser)?.executableURL else { throw ProfileError("找不到浏览器执行文件。") }
        let command = Process()
        command.executableURL = executable
        command.arguments = ["--profile-directory=\(profile)", url.absoluteString]
        command.standardOutput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        try command.run()
    }

    func stopDesktop(_ bundle: URL) async throws -> Bool {
        guard let identifier = Bundle(url: bundle)?.bundleIdentifier else { return false }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated }
        guard !apps.isEmpty else { return false }
        for app in apps { _ = app.terminate() }
        for _ in 0..<80 {
            if apps.allSatisfy(\.isTerminated) { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProfileError("客户端仍在运行。请先保存工作并退出客户端，然后重试。")
    }

    func launchCLI(_ client: Client, command: Command) async throws {
        let folder = support.appending(path: "Launchers")
        try PrivateFiles.directory(folder)
        let state = record(client)
        let launchID = UUID().uuidString
        let script = folder.appending(path: launchID + ".command")
        let arguments = command.args.map(shellQuote).joined(separator: " ")
        var envMap = command.environment
        let pathValue = searchPaths.joined(separator: ":")
        if envMap["PATH"] == nil {
            envMap["PATH"] = pathValue
        }
        let environment = envMap.sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuote($0.value))" }.joined(separator: " ")
        let targetDirectory = (command.workingDirectory ?? home).path
        let source = """
        #!/bin/sh
        umask 077
        cd \(shellQuote(targetDirectory)) || cd \(shellQuote(home.path)) || exit 1
        \(environment.isEmpty ? "" : "export " + environment)
        started=$(LC_ALL=C /bin/ps -p $$ -o lstart=)
        state=\(shellQuote(state.path))
        printf '%s\\n%s\\n%s\\n' "$$" "$started" \(shellQuote(launchID)) > "$state.$$"
        /bin/mv -f "$state.$$" "$state"
        /bin/rm -f \(shellQuote(script.path))
        exec \(shellQuote(command.executable.path)) \(arguments)
        """
        try PrivateFiles.replace(script, expected: nil, with: Data(source.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else {
            try? FileManager.default.removeItem(at: script)
            throw ProfileError("无法在终端中打开客户端。")
        }
        for _ in 0..<80 {
            if let data = try PrivateFiles.read(state),
               let nonce = String(decoding: data, as: UTF8.self).split(separator: "\n").last,
               nonce == launchID {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: script)
        throw ProfileError("终端未确认启动。请检查终端后重试。")
    }

    func stopCLI(_ client: Client) async throws -> Bool {
        let state = record(client)
        guard let data = try PrivateFiles.read(state), let text = String(data: data, encoding: .utf8) else { return false }
        let fields = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count >= 2, let pid = pid_t(fields[0]), pid > 1 else { return false }
        let launched = fields[1].trimmingCharacters(in: .whitespaces)
        guard !launched.isEmpty, startTime(pid: pid) == launched else {
            try? FileManager.default.removeItem(at: state)
            return false
        }
        guard getpgid(pid) == pid else {
            throw ProfileError("该终端客户端与其他进程共用进程组。请先在终端退出客户端。")
        }
        guard kill(-pid, SIGTERM) == 0 || errno == ESRCH else { throw ProfileError("无法退出由 AuvProfile 启动的终端客户端。") }
        for _ in 0..<40 {
            if kill(-pid, 0) == -1 && errno == ESRCH {
                try? FileManager.default.removeItem(at: state)
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProfileError("终端客户端仍在退出。请保存工作后重试。")
    }

    func isCLIRunning(_ client: Client) -> Bool {
        let state = record(client)
        guard let data = try? PrivateFiles.read(state), let text = String(data: data, encoding: .utf8) else { return false }
        let fields = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count >= 2, let pid = pid_t(fields[0]), pid > 1 else { return false }
        let launched = fields[1].trimmingCharacters(in: .whitespaces)
        guard !launched.isEmpty, startTime(pid: pid) == launched else { return false }
        return kill(pid, 0) == 0
    }

    private func record(_ client: Client) -> URL {
        support.appending(path: "Launchers/\(client.rawValue).pid")
    }

    private func startTime(pid: pid_t) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart="]
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try? process.run()
        guard process.processIdentifier > 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension URL {
    var existingExecutable: URL? { FileManager.default.isExecutableFile(atPath: path) ? self : nil }
}

func shellQuote(_ arg: String) -> String {
    "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
