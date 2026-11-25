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
    @NSApplicationDelegateAdaptor(WindowLifecycle.self) private var lifecycle
    @StateObject private var manager = ProfileManager()
    @State private var tab = Client.codex
    @State private var selectedProfileID: String?
    @State private var draft = Profile(name: "")
    @State private var showingEditor = false
    @State private var isNewProfile = false
    @State private var isSaving = false
    @State private var editorSection = EditorSection.account
    @FocusState private var editorFocus: Bool
    @State private var isDirty = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var importerMode: ImporterMode?
    @State private var showingImporter = false
    @State private var renamingBrowserProfile: Profile?
    @State private var browserRenameText = ""

    @State private var pendingDeletion: Profile?

    private enum EditorSection: String, CaseIterable {
        case account = "登录账号"
        case provider = "服务商"
        case cli = "CLI"
        case files = "配置文件"
    }

    private var profiles: [Profile] { manager.profiles[tab, default: []] }
    private var commandProfile: Profile? {
        profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first(where: \.active) ?? profiles.first
    }

    private enum ImporterMode {
        case importIntoDraft
        case pickDraftWorkingDirectory
    }

    private struct ProviderPreset: Identifiable {
        let id: String
        let title: String
        let providerId: String
        let providerName: String
        let baseUrl: String
        let envKey: String
        let wireApi: String
        let model: String
    }

    private func presets(for client: Client) -> [ProviderPreset] {
        switch client {
        case .codex:
            return [
                .init(id: "openai", title: "OpenAI 官方", providerId: "openai", providerName: "OpenAI", baseUrl: "", envKey: "", wireApi: "responses", model: ""),
                .init(id: "openrouter", title: "OpenRouter", providerId: "openrouter", providerName: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1", envKey: "OPENROUTER_API_KEY", wireApi: "chat", model: ""),
                .init(id: "deepseek", title: "DeepSeek", providerId: "deepseek", providerName: "DeepSeek", baseUrl: "https://api.deepseek.com/v1", envKey: "DEEPSEEK_API_KEY", wireApi: "chat", model: "deepseek-chat"),
                .init(id: "ollama", title: "Ollama 本地", providerId: "ollama-local", providerName: "Ollama Local", baseUrl: "http://127.0.0.1:11434/v1", envKey: "", wireApi: "chat", model: ""),
                .init(id: "lmstudio", title: "LM Studio", providerId: "lmstudio-local", providerName: "LM Studio", baseUrl: "http://127.0.0.1:1234/v1", envKey: "", wireApi: "chat", model: ""),
            ]
        case .claude:
            return [
                .init(id: "anthropic", title: "Anthropic 官方", providerId: "anthropic", providerName: "Anthropic 官方", baseUrl: "", envKey: "", wireApi: "", model: "claude-sonnet-4-20250514"),
                .init(id: "openrouter", title: "OpenRouter Claude", providerId: "openrouter", providerName: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1", envKey: "", wireApi: "", model: "anthropic/claude-sonnet-4"),
            ]
        case .antigravity:
            return [
                .init(id: "google", title: "Google 官方", providerId: "google", providerName: "Google Gemini", baseUrl: "", envKey: "", wireApi: "", model: "gemini-2.5-pro"),
            ]
        case .web:
            return []
        }
    }

    var body: some Scene {
        Window("AuvProfile", id: "profiles") {
            HStack(spacing: 0) {
                clientSidebar
                Divider()
                VStack(spacing: 0) {
                    workspace
                    Divider()
                    statusFooter
                }
            }
            .background(WorkspacePalette.background)
            .background(MainWindowRegistration(
                lifecycle: lifecycle,
                manager: manager,
                routeToMainWindow: routeToMainWindow
            ))
            .frame(minWidth: 750, minHeight: 475)
            .defaultFocus($searchFocused, false)
            .modifier(TabFocusEffect(lifecycle: lifecycle))
            .sheet(isPresented: $showingEditor, onDismiss: clearEditor) {
                editor.modifier(TabFocusEffect(lifecycle: lifecycle))
            }
            .sheet(item: $renamingBrowserProfile) { profile in
                VStack(alignment: .leading, spacing: 14) {
                    Text("重命名浏览器 Profile").font(.title3.weight(.semibold))
                    Text(profile.detail).font(.caption).foregroundStyle(.secondary)
                    TextField("自定义名称（留空恢复默认）", text: $browserRenameText)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("恢复默认") {
                            manager.renameBrowserProfile(profile, to: "")
                            renamingBrowserProfile = nil
                        }
                        Spacer()
                        Button("取消") { renamingBrowserProfile = nil }
                            .keyboardShortcut(.cancelAction)
                        Button("保存") {
                            manager.renameBrowserProfile(profile, to: browserRenameText)
                            renamingBrowserProfile = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 420)
                .modifier(TabFocusEffect(lifecycle: lifecycle))
            }
            .alert("操作未完成", isPresented: issuePresented(inEditor: false), actions: dismissIssue, message: issueMessage)
            .confirmationDialog(
                "删除配置",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { profile in
                Button("删除", role: .destructive) {
                    manager.deleteProfile(profile, for: profile.client)
                }
            } message: { profile in
                Text("确定删除「\\(profile.name)」？")
            }
        }
        .defaultSize(width: 900, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Profile") {
                Button("刷新列表") { manager.refresh() }.keyboardShortcut("r")
                Button("搜索配置…") { searchFocused = true }
                    .keyboardShortcut("f")
                    .disabled(showingEditor)
                if tab != .web {
                    Divider()
                    Button("新建 \\(tab.rawValue) 配置", action: newProfile)
                        .keyboardShortcut("n")
                        .disabled(showingEditor || manager.busy)
                    Button("复制当前选中配置") {
                        if let commandProfile { edit(manager.duplicateProfile(commandProfile)) }
                    }
                    .keyboardShortcut("d")
                    .disabled(showingEditor || manager.busy || commandProfile == nil)
                    Button(draft.active ? "保存并应用" : "保存当前配置") { saveDraft(activate: false) }
                        .keyboardShortcut("s")
                        .disabled(!showingEditor || isSaving || manager.busy)
                    Button("打开 \\(tab.rawValue) CLI 终端") {
                        manager.launchCLI(tab, profile: showingEditor ? draft : commandProfile)
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(manager.busy || (showingEditor && draft.client != tab))
                }
            }
        }

    }

    private func selectClient(_ client: Client) {
        guard tab != client else { return }
        tab = client
        search = ""
        searchFocused = false
        selectedProfileID = nil
    }

    private func routeToMainWindow(_ client: Client, action: MainWindowAction) {
        guard !showingEditor, renamingBrowserProfile == nil, pendingDeletion == nil else { return }
        selectClient(client)
        switch action {
        case .manage: break
        case .create: newProfile()
        case let .edit(profile): edit(profile)
        }
    }

    private var importerAllowedTypes: [UTType] {
        switch importerMode {
        case .importIntoDraft: [.json, .data, .plainText]
        case .pickDraftWorkingDirectory, nil: [.folder]
        }
    }

    private func openImporter(_ mode: ImporterMode) {
        importerMode = mode
        showingImporter = true
    }

    private func importFile(_ output: Result<URL, Error>) {
        guard let mode = importerMode else { return }
        importerMode = nil
        do {
            let url = try output.get()
            switch mode {
            case .importIntoDraft: try manager.importConfigOrAuthFile(url, into: &draft)
            case .pickDraftWorkingDirectory: draft.workingDirectoryPath = manager.displayPath(url)
            }
            isDirty = true
        } catch CocoaError.userCancelled {
        } catch {
            manager.issue = error.localizedDescription
        }
    }

    private func issuePresented(inEditor: Bool) -> Binding<Bool> {
        Binding(
            get: { showingEditor == inEditor && manager.issue != nil },
            set: { if !$0 { manager.issue = nil } }
        )
    }

    private func dismissIssue() -> some View {
        Button("关闭", role: .cancel) { manager.issue = nil }
    }

    private func issueMessage() -> some View {
        Text(manager.issue ?? "")
    }

    private var clientSidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("客户端")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .padding(.bottom, 5)
            ForEach(Client.allCases) { client in
                ClientNavigationButton(client: client, selected: client == tab, fillsRow: true) {
                    selectClient(client)
                }
            }
            Spacer()
            Button("刷新列表", systemImage: "arrow.clockwise", action: manager.refresh)
                .help("刷新列表（⌘R）")
                .padding(.leading, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .frame(width: 172)
        .background(WorkspacePalette.navigation)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 12) {
                Text(tab == .codex ? "ChatGPT / Codex" : tab.rawValue)
                    .font(.system(size: 30, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                TextField(tab == .web ? "搜索浏览器配置" : "搜索其他配置", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 155)
                    .focused($searchFocused)
                    .onExitCommand {
                        search = ""
                        searchFocused = false
                    }
                if tab != .web {
                    Button("新建配置", systemImage: "plus", action: newProfile)
                        .help("新建配置（⌘N）")
                }
            }

            if tab != .web, let current = profiles.first(where: \.active) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前配置").font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    currentCard(current)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                if tab != .web {
                    Text("其他配置").font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                profileList
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(manager.busy)
    }

    private var matchingRows: [Profile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.filter { profile in
            guard tab == .web || !profile.active else { return false }
            guard !query.isEmpty else { return true }
            let fields = tab == .web
                ? [profile.name, profile.detail, profile.cliBadge]
                : [profile.name, profile.accountBadge, profile.providerBadge, profile.cliBadge]
            return fields.contains { $0.localizedStandardContains(query) }
        }
    }

    private func currentCard(_ profile: Profile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 22))
                .foregroundStyle(WorkspacePalette.accent)
                .frame(width: 42, height: 42)
                .background(WorkspacePalette.selection, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("已启用")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WorkspacePalette.enabled)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(WorkspacePalette.enabledBackground, in: Capsule())
                        .fixedSize()
                }
                Text("\(profile.accountBadge) · \(profile.providerBadge)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("打开客户端", systemImage: "arrow.up.right") { manager.openDesktop(tab) }
                .buttonStyle(.borderedProminent)
                .tint(WorkspacePalette.accent)
            Button("编辑") { edit(profile) }
            profileMenu(profile)
        }
        .controlSize(.regular)
        .padding(14)
        .frame(minHeight: 76)
        .background(WorkspacePalette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspacePalette.line))
    }

    private var profileList: some View {
        let rows = matchingRows
        return Group {
            if rows.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, profile in
                            if index != 0 { Rectangle().fill(WorkspacePalette.line).frame(height: 1) }
                            profileRow(profile)
                        }
                    }
                }
            }
        }
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspacePalette.line))
    }

    private var emptyList: some View {
        VStack(spacing: 6) {
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("没有匹配的配置")
                Button("清空搜索") { search = "" }
            } else if tab == .web {
                Text("暂无浏览器配置")
                Text("在受支持的浏览器中使用独立个人资料后，点击刷新。")
                    .font(.caption)
            } else {
                Text("暂无其他配置")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func profileRow(_ profile: Profile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tab == .web ? Client.web.icon : "person.crop.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            if tab == .web {
                profileSummary(profile)
            } else {
                Button {
                    edit(profile)
                } label: {
                    profileSummary(profile)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("编辑 \\(profile.name)")
            }
            Spacer(minLength: 10)
            if tab == .web {
                Menu("打开") {
                    ForEach(WebService.allCases) { service in
                        Button(service.rawValue) { manager.openWeb(profile, service: service) }
                    }
                }
                .fixedSize()
                Menu {
                    Button("重命名…") {
                        browserRenameText = profile.name
                        renamingBrowserProfile = profile
                    }
                    Button("在访达中显示") { manager.revealInFinder(profile) }
                } label: {
                    Image(systemName: "ellipsis").accessibilityLabel("更多操作")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button("启用") {
                    selectedProfileID = profile.id
                    manager.select(profile, for: tab)
                }
                .help(tab == .codex ? "启用后会重启正在运行的 Codex" : "启用此配置")
                profileMenu(profile)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
    }

    private func profileSummary(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(profile.name).fontWeight(.medium).lineLimit(1)
                if profile.client == .web && profile.active {
                    Text("最近使用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Text(profile.client == .web ? profile.detail : "\\(profile.accountBadge) · \\(profile.providerBadge)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func profileMenu(_ profile: Profile) -> some View {
        Menu {
            Button("编辑…") { edit(profile) }
            if profile.active {
                Button("重新应用") { manager.select(profile, for: profile.client) }
            }
            Button("复制配置") { edit(manager.duplicateProfile(profile)) }
            Divider()
            Button("打开 CLI 终端") { manager.launchCLI(profile.client, profile: profile) }
            Button("复制启动命令") { manager.copyCLICommand(for: profile) }
            Button("在访达中显示") { manager.revealInFinder(profile) }
            Divider()
            Button("删除配置…", role: .destructive) { pendingDeletion = profile }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel("更多操作")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            if manager.busy {
                ProgressView().controlSize(.small)
            }
            Text(manager.busy ? "正在处理…" : manager.status)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(tab == .web ? "\(profiles.count) 个浏览器配置" : "\(profiles.count) 套配置")
                .monospacedDigit()
                .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .frame(height: 30)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNewProfile ? "新建配置" : "编辑配置")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(draft.client.rawValue)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDirty {
                    Text("有未保存修改")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)

            HStack(spacing: 17) {
                ForEach(EditorSection.allCases, id: \.self) { section in
                    let selected = section == editorSection
                    Button {
                        editorSection = section
                    } label: {
                        Text(section.rawValue)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? WorkspacePalette.accent : .secondary)
                            .padding(.horizontal, 4)
                            .frame(height: 35)
                            .overlay(alignment: .bottom) {
                                if selected { Rectangle().fill(WorkspacePalette.accent).frame(height: 2) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer()
            }
            Divider()

            ScrollView {
                Group {
                    switch editorSection {
                    case .account:
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("配置名称").font(.subheadline.weight(.medium))
                                TextField("配置名称", text: $draft.name)
                                    .focused($editorFocus)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: draft.name) { _, _ in isDirty = true }
                            }
                            accountEditorCard
                        }
                    case .provider: providerEditorCard
                    case .cli: cliEditorCard
                    case .files: configFileEditor
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
            }
            .defaultFocus($editorFocus, false)
            .frame(height: 300)
            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button("取消", role: .cancel, action: cancelEditing)
                    .keyboardShortcut(.cancelAction)
                if !draft.active {
                    Button("保存") { saveDraft(activate: false) }
                }
                Button(draft.active ? "保存并应用" : "保存并启用") { saveDraft(activate: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkspacePalette.accent)
            }
            .padding(.top, 13)
        }
        .padding(20)
        .frame(width: 616)
        .background(WorkspacePalette.background)
        .disabled(isSaving || manager.busy)
        .interactiveDismissDisabled(isSaving)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importerAllowedTypes,
            onCompletion: importFile
        )
        .alert("操作未完成", isPresented: issuePresented(inEditor: true), actions: dismissIssue, message: issueMessage)
    }

    private func edit(_ profile: Profile, isNew: Bool = false) {
        selectedProfileID = isNew ? nil : profile.id
        draft = profile
        isNewProfile = isNew
        isDirty = false
        editorSection = .account
        showingEditor = true
    }

    private func newProfile() {
        edit(manager.newProfile(for: tab), isNew: true)
    }

    private func cancelEditing() {
        showingEditor = false
    }

    private func clearEditor() {
        draft = Profile(name: "")
        isNewProfile = false
        isDirty = false
        importerMode = nil
        showingImporter = false
        editorFocus = false
    }

    private var accountEditorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button("终端登录新账号") {
                    manager.loginClient(draft.client)
                }
                .controlSize(.small)
                Button("导入凭据文件…") {
                    openImporter(.importIntoDraft)
                }
                .controlSize(.small)
            }

            Picker("认证模式", selection: $draft.authMode) {
                ForEach(AuthMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.authMode) { _, _ in isDirty = true }

            if draft.authMode == .oauth {
                if draft.client == .codex {
                    HStack(spacing: 10) {
                        Text("绑定账号")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        if manager.oauthAccounts.isEmpty {
                            Text("暂未检测到已保存的 OAuth 登录，请点击「终端登录新账号」或切换为 API Key。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("选择已保存的登录账号", selection: Binding(
                                get: { draft.oauthAccountKey ?? manager.oauthAccounts.first?.id ?? "" },
                                set: { newKey in
                                    draft.oauthAccountKey = newKey
                                    draft.oauthAccountLabel = manager.oauthAccounts.first(where: { $0.id == newKey })?.label
                                    isDirty = true
                                }
                            )) {
                                ForEach(manager.oauthAccounts) { option in
                                    Text(option.label).tag(option.id)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.secondary)
                        Text(draft.client == .claude
                             ? "使用 Claude 客户端 / CLI 的交互式 OAuth 登录会话。点击「终端登录新账号」可重新登录。"
                             : "使用 Antigravity 的 Google OAuth 登录会话。点击「终端登录新账号」可唤起登录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                    GridRow {
                        Text(draft.client == .codex ? "OpenAI API Key" : (draft.client == .claude ? "Anthropic Key / Token" : "Gemini API Key"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        SecureField(
                            draft.client == .codex
                                ? "sk-... (启用时写入 ~/.codex/auth.json)"
                                : (draft.client == .claude ? "sk-ant-... (启用时写入 ANTHROPIC_AUTH_TOKEN)" : "AIza... (启用时写入 GEMINI_API_KEY)"),
                            text: $draft.apiKey
                        )
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draft.apiKey) { _, _ in isDirty = true }
                    }
                }
                Text("密钥将加密保存在 macOS 系统钥匙串中。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var providerEditorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu("使用服务商模板") {
                    ForEach(presets(for: draft.client)) { preset in
                        Button(preset.title) {
                            draft.providerId = preset.providerId
                            draft.providerName = preset.providerName
                            draft.baseUrl = preset.baseUrl
                            draft.envKey = preset.envKey
                            if !preset.wireApi.isEmpty { draft.wireApi = preset.wireApi }
                            if !preset.model.isEmpty { draft.model = preset.model }
                            isDirty = true
                        }
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                if draft.client == .codex {
                    GridRow {
                        Text("服务商 ID")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            TextField("openai 或自定义 ID (如 openrouter)", text: $draft.providerId)
                                .frame(maxWidth: 200)
                                .onChange(of: draft.providerId) { _, _ in isDirty = true }
                            Text("显示名称")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                            TextField("例如 OpenRouter", text: $draft.providerName)
                                .onChange(of: draft.providerName) { _, _ in isDirty = true }
                        }
                    }
                }

                GridRow {
                    Text("Base URL")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    TextField(
                        draft.client == .codex
                            ? "留空使用 OpenAI 官方地址，或填 https://openrouter.ai/api/v1"
                            : (draft.client == .claude ? "留空使用 Anthropic 官方，或填 ANTHROPIC_BASE_URL" : "留空使用 Google 官方，或填 GOOGLE_GEMINI_BASE_URL"),
                        text: $draft.baseUrl
                    )
                    .onChange(of: draft.baseUrl) { _, _ in isDirty = true }
                }

                GridRow {
                    Text("默认模型")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    TextField(
                        draft.client == .codex
                            ? "可选，例如 o3 / gpt-5 / deepseek-chat"
                            : (draft.client == .claude ? "可选 ANTHROPIC_MODEL (如 claude-sonnet-4-20250514)" : "可选 GEMINI_MODEL (如 gemini-2.5-pro)"),
                        text: $draft.model
                    )
                    .onChange(of: draft.model) { _, _ in isDirty = true }
                }

                if draft.client == .codex && draft.providerId != "openai" && !draft.providerId.isEmpty {
                    GridRow {
                        Text("Wire API")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Picker("Wire API", selection: $draft.wireApi) {
                                Text("responses (Responses API)").tag("responses")
                                Text("chat (Chat Completions)").tag("chat")
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                            .onChange(of: draft.wireApi) { _, _ in isDirty = true }

                            Toggle("需要 OpenAI 账号认证", isOn: $draft.requiresOpenaiAuth)
                                .font(.system(size: 12))
                                .onChange(of: draft.requiresOpenaiAuth) { _, _ in isDirty = true }
                        }
                    }
                    GridRow {
                        Text("服务商鉴权")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            TextField("环境变量名 (如 OPENROUTER_API_KEY)", text: $draft.envKey)
                                .onChange(of: draft.envKey) { _, _ in isDirty = true }
                            SecureField("或直接填 Bearer Token", text: $draft.bearerToken)
                                .onChange(of: draft.bearerToken) { _, _ in isDirty = true }
                        }
                    }
                }

                if draft.client == .antigravity {
                    GridRow {
                        Text("Cloud Project")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        TextField("可选 GOOGLE_CLOUD_PROJECT (Vertex AI 项目 ID)", text: $draft.cloudProject)
                            .onChange(of: draft.cloudProject) { _, _ in isDirty = true }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var cliEditorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    manager.copyCLICommand(for: draft)
                } label: {
                    Label("复制启动命令", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)

                Button {
                    manager.launchCLI(draft.client, profile: draft)
                } label: {
                    Label("打开 CLI 终端", systemImage: "play.fill")
                }
                .controlSize(.small)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                GridRow {
                    Text("启动工作目录")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("默认主目录 (~)，可指定具体代码工程目录", text: $draft.workingDirectoryPath)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: draft.workingDirectoryPath) { _, _ in isDirty = true }
                        Button("选择目录…") {
                            openImporter(.pickDraftWorkingDirectory)
                        }
                        .controlSize(.small)
                    }
                }
                GridRow {
                    Text("附加 CLI 参数")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    TextField("可选，启动 CLI 时附加的命令行参数", text: $draft.extraCLIArgs)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draft.extraCLIArgs) { _, _ in isDirty = true }
                }
            }

        }
    }

    private var configFileEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(draft.client == .codex ? "config.toml" : "settings.json")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("导入配置…") { openImporter(.importIntoDraft) }
                Button("从表单更新配置文件") {
                    do {
                        draft.configText = try manager.synthesizeConfigText(for: draft)
                        isDirty = true
                    } catch {
                        manager.issue = error.localizedDescription
                    }
                }
                if draft.client != .codex {
                    Button("格式化 JSON", action: formatDraftJSON)
                }
            }
            .controlSize(.small)

            CodeTextEditor(text: Binding(
                get: { draft.configText },
                set: { newValue in
                    draft.configText = newValue
                    isDirty = true
                }
            ))
            .frame(height: 207)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WorkspacePalette.line))
        }
    }

    private func formatDraftJSON() {
        guard let data = draft.configText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let formatted = String(data: pretty, encoding: .utf8) else {
            manager.issue = "当前配置文本不是有效的 JSON 对象，无法格式化。"
            return
        }
        draft.configText = formatted + "\n"
    }

    private func saveDraft(activate: Bool) {
        guard showingEditor, !isSaving, !manager.busy else { return }
        isSaving = true
        let submittedDraft = draft
        Task {
            defer { isSaving = false }
            do {
                let saved = try await manager.saveProfile(submittedDraft, activate: activate)
                if tab == saved.client { selectedProfileID = saved.id }
                showingEditor = false
            } catch {
                manager.issue = error.localizedDescription
            }
        }
    }
}

private struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    @EnvironmentObject private var lifecycle: WindowLifecycle

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.focusRingType = lifecycle.showsTabFocus ? .default : .none
        textView.focusRingType = scrollView.focusRingType
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextEditor
        init(_ parent: CodeTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
