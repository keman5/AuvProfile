import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum AuvProfileMain {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-iconset" {
            try AppIcon.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            return
        }
        AuvProfileApp.main()
    }
}

struct AuvProfileApp: App {
    @StateObject private var manager = ProfileManager()
    @State private var tab = Client.codex
    @State private var search = ""
    @State private var sheet: Editor?
    @State private var showImporter = false
    @State private var directoryClient: Client?

    var body: some Scene {
        Window("AuvProfile", id: "profiles") {
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if tab == .codex, let discoveryIssue = manager.discoveryIssue {
                        Label(discoveryIssue, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    results
                    footer
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 690, minHeight: 460)
            .sheet(item: $sheet) { editor in
                EditorView(editor: editor, manager: manager)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [directoryClient == nil ? .json : .folder]) { output in
                do {
                    let url = try output.get()
                    if let directoryClient {
                        manager.addDirectory(url, for: directoryClient)
                    } else {
                        try manager.importCodexAccount(from: url)
                    }
                }
                catch { manager.issue = error.localizedDescription }
            }
            .alert("操作未完成", isPresented: Binding(
                get: { manager.issue != nil },
                set: { if !$0 { manager.issue = nil } }
            )) {
                Button("关闭", role: .cancel) { manager.issue = nil }
            } message: {
                Text(manager.issue ?? "")
            }
        }
        .defaultSize(width: 880, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Profile") {
                Button("刷新列表") { manager.refresh() }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra("AuvProfile", systemImage: "person.crop.rectangle.stack") {
            MenuBarProfiles(manager: manager, selectedClient: $tab)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("AuvProfile", systemImage: "person.crop.rectangle.stack")
                .font(.headline)
                .padding(.horizontal, 10)
            VStack(spacing: 5) {
                ForEach(Client.allCases) { client in
                    Button {
                        tab = client
                        search = ""
                    } label: {
                        Label(client.rawValue, systemImage: client.icon)
                            .font(.system(size: 13, weight: client == tab ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 10)
                            .background(client == tab ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(client == tab ? .isSelected : [])
                }
            }
            Spacer()
        }
        .padding(14)
        .padding(.top, 10)
        .frame(width: 170)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tab == .codex ? "ChatGPT & Codex" : tab.rawValue)
                    .font(.system(size: 30, weight: .semibold))
                Spacer()
                Menu {
                    if tab == .codex {
                        Button("登录新账号") { manager.loginCodex() }
                        Button("导入 Codex 登录文件…") {
                            directoryClient = nil
                            showImporter = true
                        }
                        Button("添加服务商") { sheet = .provider(.init(wireApi: "responses")) }
                    }
                    if tab == .claude || tab == .antigravity {
                        Button("新建 CLI profile") { sheet = .directory(tab) }
                        Button("导入配置目录…") {
                            directoryClient = tab
                            showImporter = true
                        }
                    }
                    if tab != .web {
                        Button("打开 CLI") { manager.launchCLI(tab) }
                        Button("打开桌面客户端") { manager.openDesktop(tab) }
                    }
                    Button("刷新") { manager.refresh() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("客户端操作")
                .disabled(manager.busy)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 profile、服务商或配置", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索 profile")
                if !search.isEmpty {
                    Button("清除", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                }
            }
            .padding(9)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var displayed: [Profile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.profiles[tab, default: []].filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.detail.localizedStandardContains(query)
        }
    }

    private var results: some View {
        Group {
            if displayed.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "暂无 profile" : "没有匹配的 profile",
                    systemImage: search.isEmpty ? "person.crop.rectangle" : "magnifyingglass",
                    description: search.isEmpty && tab == .web ? Text("打开 Chrome 或 Edge 并登录对应网站后，浏览器 profile 会自动显示。") : nil
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(displayed) { profile in
                            row(profile)
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
    }

    private func row(_ profile: Profile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: profile.kind.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(profile.active ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(profile.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if profile.active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("当前")
            }
            if profile.kind == .browser {
                Menu("打开") {
                    ForEach(WebService.allCases) { service in
                        Button(service.rawValue) { manager.openWeb(profile, service: service) }
                    }
                }
                .fixedSize()
            } else {
                if profile.kind == .codexProvider, let provider = manager.provider(profile) {
                    Button("编辑") { sheet = .provider(provider) }
                } else if let file = manager.configFor(profile, client: tab) {
                    Button("配置") {
                        do {
                            let (text, original) = try manager.readConfig(file)
                            sheet = .configuration(file, text, original)
                        } catch { manager.issue = error.localizedDescription }
                    }
                }
                if profile.kind == .codexAccount && !profile.active {
                    Menu {
                        Button("移除已保存的登录", role: .destructive) {
                            do { try manager.forgetAccount(profile) }
                            catch { manager.issue = error.localizedDescription }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .fixedSize()
                    .accessibilityLabel("账号操作")
                }
                Button(profile.kind == .antigravity || profile.kind == .claudeDesktop ? "重启" : "启用") {
                    manager.select(profile, for: tab)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.46), in: RoundedRectangle(cornerRadius: 9))
        .disabled(manager.busy)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if manager.busy { ProgressView().controlSize(.small) }
            Text(manager.busy ? "正在应用配置…" : manager.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(displayed.count) 个 profile")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 16)
    }
}

private struct MenuBarProfiles: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var manager: ProfileManager
    @Binding var selectedClient: Client

    var body: some View {
        Button("管理 profiles") { showWindow(.codex) }
        Divider()
        ForEach(Client.allCases) { client in
            Menu(client.rawValue) {
                let rows = manager.profiles[client, default: []]
                if rows.isEmpty {
                    Button("查看 profiles") { showWindow(client) }
                }
                ForEach(rows) { profile in
                    if profile.kind == .browser {
                        Menu(profile.name) {
                            ForEach(WebService.allCases) { service in
                                Button(service.rawValue) { manager.openWeb(profile, service: service) }
                            }
                        }
                    } else {
                        Button {
                            manager.select(profile, for: client)
                        } label: {
                            Label(profile.name, systemImage: profile.active ? "checkmark.circle.fill" : profile.kind.icon)
                        }
                    }
                }
            }
        }
        .disabled(manager.busy)
        if let issue = manager.issue {
            Divider()
            Button(issue) { showWindow(.codex) }
        }
        Divider()
        Button("退出 AuvProfile") { NSApplication.shared.terminate(nil) }
    }

    private func showWindow(_ client: Client) {
        selectedClient = client
        openWindow(id: "profiles")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private extension ProfileKind {
    var icon: String {
        switch self {
        case .codexAccount: "person.crop.circle"
        case .codexConfig, .codexOverlay, .claudeDirectory, .antigravityCLI: "terminal"
        case .codexProvider: "point.3.connected.trianglepath.dotted"
        case .antigravity, .claudeDesktop: "macwindow"
        case .browser: "globe"
        }
    }
}

private enum Editor: Identifiable {
    case provider(Provider)
    case configuration(URL, String, Data?)
    case directory(Client)
    var id: String {
        switch self {
        case .provider(let provider): "provider/" + provider.id
        case .configuration(let file, _, _): file.path
        case .directory(let client): "directory/" + client.id
        }
    }
}

private struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ProfileManager
    let editor: Editor
    @State private var provider: Provider
    @State private var text: String
    @State private var issue = ""
    @State private var saving = false
    private let existingProvider: Bool

    init(editor: Editor, manager: ProfileManager) {
        self.editor = editor
        self.manager = manager
        switch editor {
        case let .provider(provider):
            _provider = State(initialValue: provider)
            _text = State(initialValue: "")
            existingProvider = !provider.id.isEmpty
        case let .configuration(_, text, _):
            _provider = State(initialValue: .init())
            _text = State(initialValue: text)
            existingProvider = false
        case .directory:
            _provider = State(initialValue: .init())
            _text = State(initialValue: "")
            existingProvider = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch editor {
            case .provider:
                Text("Codex 服务商").font(.title2.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 11) {
                    GridRow { Text("ID"); TextField("例如 my-provider", text: $provider.id).disabled(existingProvider) }
                    GridRow { Text("名称"); TextField("显示名称", text: field(\.name)) }
                    GridRow { Text("Base URL"); TextField("https://example.com/v1", text: field(\.baseUrl)) }
                    GridRow { Text("环境变量"); TextField("例如 MY_API_KEY", text: field(\.envKey)) }
                    GridRow { Text("Bearer Token"); SecureField("experimental_bearer_token", text: field(\.experimentalBearerToken)) }
                    GridRow { Text("Wire API"); TextField("responses", text: field(\.wireApi)) }
                    GridRow {
                        Text("OpenAI 登录")
                        Toggle("使用 OpenAI 登录", isOn: Binding(
                            get: { provider.requiresOpenaiAuth ?? false },
                            set: { provider.requiresOpenaiAuth = $0 }
                        ))
                        .labelsHidden()
                    }
                }
            case let .configuration(file, _, _):
                Text(file.lastPathComponent).font(.title2.weight(.semibold))
                Text(file.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)
                    .frame(minHeight: 310)
                    .border(.quaternary)
            case let .directory(client):
                Text("新建 \(client.rawValue) CLI profile").font(.title2.weight(.semibold))
                TextField("配置名称", text: $text)
            }
            if !issue.isEmpty {
                Text(issue).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 560)
        .disabled(saving)
        .onExitCommand { if !saving { dismiss() } }
    }

    private func field(_ path: WritableKeyPath<Provider, String?>) -> Binding<String> {
        Binding(get: { provider[keyPath: path] ?? "" }, set: { provider[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                switch editor {
                case .provider(let original): try manager.saveProvider(provider, originalProvider: existingProvider ? original : nil)
                case let .configuration(file, _, original): try manager.saveConfig(text, file: file, original: original)
                case let .directory(client): try manager.createDirectory(named: text, for: client)
                }
                dismiss()
            } catch { issue = error.localizedDescription }
        }
    }
}
