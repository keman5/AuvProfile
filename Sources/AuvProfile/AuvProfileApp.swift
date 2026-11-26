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
    @AppStorage(WindowLifecycle.hideDockDefaultsKey) private var hideDockOnClose = true
    @State private var tab = Client.codex
    @State private var hoveredTab: Client?
    @State private var hoveredProfileID: String?
    @State private var selectedProfileID: String?
    @State private var isDrawerOpen = false
    @State private var showRawCodeInDrawer = false
    @State private var showSettingsSheet = false
    @State private var pendingActivationProfile: Profile?
    @State private var draft = Profile(name: "默认配置")
    @State private var isDirty = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var importerMode: ImporterMode?
    @State private var renamingBrowserProfile: Profile?
    @State private var browserRenameText = ""

    private enum ImporterMode {
        case importIntoDraft
        case pickDraftWorkingDirectory
        case pickGlobalWorkingDirectory
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
                .init(id: "openai", title: "OpenAI", providerId: "openai", providerName: "OpenAI", baseUrl: "", envKey: "", wireApi: "responses", model: ""),
                .init(id: "openrouter", title: "OpenRouter", providerId: "openrouter", providerName: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1", envKey: "OPENROUTER_API_KEY", wireApi: "chat", model: ""),
                .init(id: "deepseek", title: "DeepSeek", providerId: "deepseek", providerName: "DeepSeek", baseUrl: "https://api.deepseek.com/v1", envKey: "DEEPSEEK_API_KEY", wireApi: "chat", model: "deepseek-chat"),
                .init(id: "ollama", title: "Ollama", providerId: "ollama-local", providerName: "Ollama", baseUrl: "http://127.0.0.1:11434/v1", envKey: "", wireApi: "chat", model: ""),
                .init(id: "lmstudio", title: "LM Studio", providerId: "lmstudio-local", providerName: "LM Studio", baseUrl: "http://127.0.0.1:1234/v1", envKey: "", wireApi: "chat", model: ""),
            ]
        case .claude:
            return [
                .init(id: "anthropic", title: "Anthropic", providerId: "anthropic", providerName: "Anthropic 官方", baseUrl: "", envKey: "", wireApi: "", model: "claude-sonnet-4-20250514"),
                .init(id: "openrouter", title: "OpenRouter", providerId: "openrouter", providerName: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1", envKey: "", wireApi: "", model: "anthropic/claude-sonnet-4"),
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
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.07), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 520
                )
                .ignoresSafeArea()

                HStack(spacing: 0) {
                    floatingSidebar
                    if tab == .web {
                        webStage
                    } else {
                        mainProfileStage
                    }
                    if isDrawerOpen && tab != .web {
                        slideOverDrawer
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .modifier(TabFocusEffect(lifecycle: lifecycle))
            .background(
                MainWindowRegistration(lifecycle: lifecycle, manager: manager) { targetClient, action in
                    tab = targetClient
                    switch action {
                    case .manage:
                        syncSelection(for: targetClient)
                    case .create:
                        let created = manager.newProfile(for: targetClient)
                        openDrawer(for: created)
                    case .edit(let profile):
                        openDrawer(for: profile)
                    }
                }
            )
            .frame(minWidth: 940, minHeight: 580)
            .onAppear {
                syncSelection(for: tab)
            }
            .onChange(of: tab) { _, newTab in
                search = ""
                withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                    isDrawerOpen = false
                }
                syncSelection(for: newTab)
            }
            .fileImporter(
                isPresented: Binding(
                    get: { importerMode != nil },
                    set: { if !$0 { importerMode = nil } }
                ),
                allowedContentTypes: importerAllowedTypes
            ) { output in
                let mode = importerMode
                importerMode = nil
                do {
                    let url = try output.get()
                    switch mode {
                    case .importIntoDraft:
                        try manager.importConfigOrAuthFile(url, into: &draft)
                        isDirty = true
                    case .pickDraftWorkingDirectory:
                        draft.workingDirectoryPath = manager.displayPath(url)
                        isDirty = true
                    case .pickGlobalWorkingDirectory:
                        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: "cli.workingDirectory")
                        manager.refresh()
                    case nil:
                        break
                    }
                } catch {
                    manager.issue = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSettingsSheet) {
                settingsSheetView
            }
            .sheet(item: $renamingBrowserProfile) { profile in
                VStack(alignment: .leading, spacing: 14) {
                    Text("重命名浏览器配置").font(.title3.weight(.semibold))
                    Text(profile.detail).font(.caption).foregroundStyle(.secondary)
                    DrawerTextField(placeholder: "自定义名称（留空恢复默认）", text: $browserRenameText)
                    HStack {
                        Button("恢复默认") {
                            manager.renameBrowserProfile(profile, to: "")
                            renamingBrowserProfile = nil
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                        Spacer()
                        Button("取消") { renamingBrowserProfile = nil }
                            .buttonStyle(SecondaryPillButtonStyle())
                            .keyboardShortcut(.cancelAction)
                        Button("保存") {
                            manager.renameBrowserProfile(profile, to: browserRenameText)
                            renamingBrowserProfile = nil
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 400)
            }
            .alert(
                "确认启用配置？",
                isPresented: Binding(
                    get: { pendingActivationProfile != nil },
                    set: { if !$0 { pendingActivationProfile = nil } }
                ),
                presenting: pendingActivationProfile
            ) { profile in
                Button("确认启用") {
                    manager.select(profile, for: profile.client)
                    pendingActivationProfile = nil
                }
                Button("取消", role: .cancel) {
                    pendingActivationProfile = nil
                }
            } message: { profile in
                Text("即将启用「\(profile.name)」（账号：\(profile.accountBadge)，服务商：\(profile.providerBadge)）。启用后将同步更新本地配置文件\(profile.client == .codex ? "并重启运行中的客户端" : "")。")
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
        .defaultSize(width: 1020, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("设置…") { showSettingsSheet = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Profile") {
                Button("刷新列表") { manager.refresh() }
                    .keyboardShortcut("r")
                Button("搜索配置…") { searchFocused = true }
                    .keyboardShortcut("f")
                if tab != .web {
                    Divider()
                    Button("新建 \(tab.rawValue) 配置") {
                        createNewAndOpenDrawer()
                    }
                    .keyboardShortcut("n")
                    Button("复制当前配置") {
                        duplicateAndOpenDrawer(draft)
                    }
                    .keyboardShortcut("d")
                    if isDrawerOpen {
                        Button("保存当前编辑") {
                            saveDraft(activate: false, closeDrawer: false)
                        }
                        .keyboardShortcut("s")
                        Button("收起编辑抽屉") {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                                isDrawerOpen = false
                            }
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    Button("打开 \(tab.rawValue) CLI 终端") {
                        manager.launchCLI(tab, profile: draft)
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                }
            }
        }
    }

    private var importerAllowedTypes: [UTType] {
        switch importerMode {
        case .importIntoDraft: [.json, .data, .plainText]
        case .pickDraftWorkingDirectory, .pickGlobalWorkingDirectory, nil: [.folder]
        }
    }

    private func syncSelection(for client: Client) {
        guard client != .web else { return }
        let list = manager.profiles[client] ?? []
        if let currentID = selectedProfileID,
           let match = list.first(where: { $0.id == currentID }) {
            draft = match
            isDirty = false
        } else if let active = list.first(where: \.active) ?? list.first {
            selectedProfileID = active.id
            draft = active
            isDirty = false
        }
    }

    private func openDrawer(for profile: Profile) {
        selectedProfileID = profile.id
        draft = profile
        isDirty = false
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            isDrawerOpen = true
        }
    }

    private func createNewAndOpenDrawer() {
        let created = manager.newProfile(for: tab)
        openDrawer(for: created)
    }

    private func duplicateAndOpenDrawer(_ source: Profile) {
        let copy = manager.duplicateProfile(source)
        openDrawer(for: copy)
    }

    // MARK: - Left Floating Translucent Sidebar

    private var floatingSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle.stack.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("AuvProfile")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("应用设置 (⌘,)")
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            VStack(spacing: 5) {
                ForEach(Client.allCases) { client in
                    let isSelected = (client == tab)
                    let isHovered = (hoveredTab == client)
                    let count = manager.profiles[client, default: []].count

                    Button {
                        tab = client
                    } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                                .frame(width: 7, height: 7)

                            Image(systemName: client.icon)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .frame(width: 16)

                            Text(client.rawValue)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            Text("\(count)")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                                )
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(
                                    isSelected
                                        ? Color.accentColor.opacity(0.15)
                                        : (isHovered ? Color.primary.opacity(0.06) : .clear)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            hoveredTab = client
                        } else if hoveredTab == client {
                            hoveredTab = nil
                        }
                    }
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text("当前生效")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(manager.activeSummary(for: tab))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
            )
        }
        .padding(12)
        .frame(width: 184)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
        .padding(.leading, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Main Stage: Adaptive Bento Profile Cards

    private var displayedProfiles: [Profile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.profiles[tab, default: []].filter {
            query.isEmpty
                || $0.name.localizedStandardContains(query)
                || $0.accountBadge.localizedStandardContains(query)
                || $0.providerBadge.localizedStandardContains(query)
                || $0.cliBadge.localizedStandardContains(query)
        }
    }

    private var mainProfileStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Clean Header (No "方案画廊" or tip pill!)
            HStack(spacing: 10) {
                Text(tab.rawValue)
                    .font(.system(size: 22, weight: .bold))

                Spacer()

                // Search Box
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("搜索配置", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                        .frame(width: 130)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { searchFocused = true }

                Button {
                    manager.openDesktop(tab)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "macwindow")
                        Text("桌面端")
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())

                Button {
                    createNewAndOpenDrawer()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                        Text("新建配置")
                    }
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }

            // Adaptive Bento Grid (Never overflows or pushes sidebar off-screen!)
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 250, maximum: 460), spacing: 14)
                    ],
                    spacing: 14
                ) {
                    ForEach(displayedProfiles) { profile in
                        bentoPasscard(profile)
                    }
                    newProfilePlaceholderCard
                }
                .padding(.vertical, 4)
            }

            // Minimal Bottom Status Bar
            if manager.busy || !manager.status.isEmpty {
                HStack(spacing: 8) {
                    if manager.busy {
                        ProgressView().controlSize(.small)
                    }
                    Text(manager.busy ? "正在应用配置…" : manager.status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Individual Bento Profile Card (Icon-Only Bottom Actions, Confirmation on Enable)

    private func bentoPasscard(_ profile: Profile) -> some View {
        let isEditingThis = isDrawerOpen && selectedProfileID == profile.id
        let isHovered = hoveredProfileID == profile.id

        return VStack(alignment: .leading, spacing: 11) {
            // Top Row: Title, Account Subtitle, and Status / Enable Button
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: profile.authMode == .oauth ? "person.crop.circle.fill" : "key.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(profile.active ? Color.accentColor : .secondary)
                        Text(profile.accountBadge)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(profile.active ? Color.accentColor : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)

                if profile.active {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("当前生效")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: Capsule())
                } else {
                    Button {
                        pendingActivationProfile = profile
                    } label: {
                        Text("启用")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(isHovered ? 0.15 : 0.08), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Middle Row: Metadata Pills (Provider / CLI / Working Dir)
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                    Text(profile.providerBadge)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(profile.active ? Color.accentColor : .primary.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    (profile.active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)),
                    in: RoundedRectangle(cornerRadius: 6)
                )

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                    Text(profile.cliBadge)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                if !profile.workingDirectoryPath.isEmpty {
                    Text(profile.workingDirectoryPath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider().opacity(0.5)

            // Bottom Row: Icon-Only Action Buttons
            HStack(spacing: 6) {
                CardIconButton(
                    icon: "slider.horizontal.3",
                    tooltip: "编辑配置",
                    highlighted: isEditingThis
                ) {
                    openDrawer(for: profile)
                }

                CardIconButton(
                    icon: "doc.on.doc",
                    tooltip: "复制配置"
                ) {
                    duplicateAndOpenDrawer(profile)
                }

                CardIconButton(
                    icon: "terminal",
                    tooltip: "打开 CLI 终端"
                ) {
                    manager.launchCLI(tab, profile: profile)
                }

                CardIconButton(
                    icon: "doc.on.clipboard",
                    tooltip: "复制终端启动命令"
                ) {
                    manager.copyCLICommand(for: profile)
                }

                CardIconButton(
                    icon: "folder",
                    tooltip: "在访达中显示配置文件"
                ) {
                    manager.revealInFinder(profile)
                }

                Spacer()

                if !profile.active {
                    CardIconButton(
                        icon: "trash",
                        tooltip: "删除配置",
                        isDestructive: true
                    ) {
                        if selectedProfileID == profile.id {
                            isDrawerOpen = false
                        }
                        manager.deleteProfile(profile, for: tab)
                        syncSelection(for: tab)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(
                    profile.active
                        ? LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.14),
                                Color(nsColor: .controlBackgroundColor).opacity(0.95),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [
                                Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.98 : 0.84),
                                Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.92 : 0.74),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(
                    profile.active
                        ? Color.accentColor.opacity(0.75)
                        : (isEditingThis
                            ? Color.accentColor.opacity(0.55)
                            : (isHovered ? Color.primary.opacity(0.22) : Color.primary.opacity(0.10))),
                    lineWidth: profile.active ? 1.8 : 1
                )
        )
        .shadow(
            color: profile.active ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.05),
            radius: profile.active ? 10 : 4,
            y: 3
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredProfileID = profile.id
            } else if hoveredProfileID == profile.id {
                hoveredProfileID = nil
            }
        }
        .contextMenu {
            if !profile.active {
                Button("启用此配置…") {
                    pendingActivationProfile = profile
                }
            }
            Button("编辑配置…") {
                openDrawer(for: profile)
            }
            Button("复制配置") {
                duplicateAndOpenDrawer(profile)
            }
            Divider()
            Button("打开 CLI 终端") {
                manager.launchCLI(tab, profile: profile)
            }
            Button("复制终端启动命令") {
                manager.copyCLICommand(for: profile)
            }
            Button("在访达中显示配置文件") {
                manager.revealInFinder(profile)
            }
            if !profile.active {
                Divider()
                Button("删除配置", role: .destructive) {
                    if selectedProfileID == profile.id {
                        isDrawerOpen = false
                    }
                    manager.deleteProfile(profile, for: tab)
                    syncSelection(for: tab)
                }
            }
        }
    }

    private var newProfilePlaceholderCard: some View {
        Button {
            createNewAndOpenDrawer()
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("新建配置")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                Text("在同一套配置中组合「登录账号 + 模型服务商 + CLI 配置」")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 126)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                    .foregroundStyle(Color.primary.opacity(0.18))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slide-Over Inspector Drawer (Custom Styled Controls, Strictly Bounded Width)

    private var slideOverDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Drawer Header
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                Text("编辑配置")
                    .font(.system(size: 13.5, weight: .bold))
                Text("· \(draft.name)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                        isDrawerOpen = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭抽屉 (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Drawer Scrollable Body
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 0. Profile Name Card
                    VStack(alignment: .leading, spacing: 6) {
                        Text("配置名称")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        DrawerTextField(placeholder: "例如 OpenRouter 开发", text: $draft.name)
                            .onChange(of: draft.name) { _, _ in isDirty = true }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))

                    // 1. Account & Auth Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("① 登录账号与认证")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button("终端登录") {
                                manager.loginClient(tab)
                            }
                            .buttonStyle(MiniPillButtonStyle())
                            Button("导入文件…") {
                                importerMode = .importIntoDraft
                            }
                            .buttonStyle(MiniPillButtonStyle())
                        }

                        // Custom Segmented Pill Picker (Replaces ugly NSSegmentedControl)
                        HStack(spacing: 4) {
                            ForEach(AuthMode.allCases) { mode in
                                let selected = (draft.authMode == mode)
                                Button {
                                    draft.authMode = mode
                                    isDirty = true
                                } label: {
                                    Text(mode.rawValue)
                                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                        .foregroundStyle(selected ? .white : .secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5.5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(selected ? Color.accentColor : .clear)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                        if draft.authMode == .oauth {
                            if tab == .codex {
                                if manager.oauthAccounts.isEmpty {
                                    Text("暂无已保存的 OAuth 账号，请点击「终端登录」或切换为 API Key。")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Menu {
                                        ForEach(manager.oauthAccounts) { option in
                                            Button {
                                                draft.oauthAccountKey = option.id
                                                draft.oauthAccountLabel = option.label
                                                isDirty = true
                                            } label: {
                                                HStack {
                                                    Text(option.label)
                                                    if (draft.oauthAccountKey ?? manager.oauthAccounts.first?.id) == option.id {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "person.crop.circle")
                                                .foregroundStyle(Color.accentColor)
                                            Text(draft.oauthAccountLabel ?? manager.oauthAccounts.first?.label ?? "选择账号")
                                                .font(.system(size: 12))
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Text("复用客户端已有的 OAuth 登录会话，可点「终端登录」刷新。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            DrawerSecureField(
                                placeholder: tab == .codex
                                    ? "输入 OPENAI_API_KEY (sk-...)"
                                    : (tab == .claude ? "输入 ANTHROPIC_AUTH_TOKEN" : "输入 GEMINI_API_KEY"),
                                text: $draft.apiKey
                            )
                            .onChange(of: draft.apiKey) { _, _ in isDirty = true }
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))

                    // 2. Model Provider Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("② 模型服务商")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }

                        // Preset Chips Row
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(presets(for: tab)) { preset in
                                    let isCurrentPreset = (draft.providerId == preset.providerId && draft.baseUrl == preset.baseUrl)
                                    Button {
                                        draft.providerId = preset.providerId
                                        draft.providerName = preset.providerName
                                        draft.baseUrl = preset.baseUrl
                                        draft.envKey = preset.envKey
                                        if !preset.wireApi.isEmpty { draft.wireApi = preset.wireApi }
                                        if !preset.model.isEmpty { draft.model = preset.model }
                                        isDirty = true
                                    } label: {
                                        Text(preset.title)
                                            .font(.system(size: 11, weight: isCurrentPreset ? .semibold : .regular))
                                            .foregroundStyle(isCurrentPreset ? Color.accentColor : .secondary)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule()
                                                    .fill(isCurrentPreset ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                                            )
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(isCurrentPreset ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if tab == .codex {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("服务商 ID").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    DrawerTextField(placeholder: "如 openrouter", text: $draft.providerId)
                                        .onChange(of: draft.providerId) { _, _ in isDirty = true }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("显示名称").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    DrawerTextField(placeholder: "如 OpenRouter", text: $draft.providerName)
                                        .onChange(of: draft.providerName) { _, _ in isDirty = true }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Base URL (留空使用官方默认地址)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            DrawerTextField(placeholder: "https://...", text: $draft.baseUrl)
                                .onChange(of: draft.baseUrl) { _, _ in isDirty = true }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("默认模型 (可选)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            DrawerTextField(placeholder: "例如 o3-pro / claude-sonnet-4", text: $draft.model)
                                .onChange(of: draft.model) { _, _ in isDirty = true }
                        }

                        if tab == .codex && draft.providerId != "openai" && !draft.providerId.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("接口协议 (Wire API)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    Spacer()
                                    Toggle("需 OpenAI 认证", isOn: $draft.requiresOpenaiAuth)
                                        .toggleStyle(.checkbox)
                                        .font(.system(size: 11))
                                        .onChange(of: draft.requiresOpenaiAuth) { _, _ in isDirty = true }
                                }
                                HStack(spacing: 4) {
                                    ForEach(["responses", "chat"], id: \.self) { api in
                                        let selected = (draft.wireApi == api)
                                        Button {
                                            draft.wireApi = api
                                            isDirty = true
                                        } label: {
                                            Text(api)
                                                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                                .foregroundStyle(selected ? .white : .secondary)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 4.5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(selected ? Color.accentColor : .clear)
                                                )
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(3)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("服务商环境变量名 (可选)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                DrawerTextField(placeholder: "如 OPENROUTER_API_KEY", text: $draft.envKey)
                                    .onChange(of: draft.envKey) { _, _ in isDirty = true }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bearer Token (可选)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                DrawerSecureField(placeholder: "experimental_bearer_token", text: $draft.bearerToken)
                                    .onChange(of: draft.bearerToken) { _, _ in isDirty = true }
                            }
                        }

                        if tab == .antigravity {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cloud Project (可选)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                DrawerTextField(placeholder: "GOOGLE_CLOUD_PROJECT", text: $draft.cloudProject)
                                    .onChange(of: draft.cloudProject) { _, _ in isDirty = true }
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))

                    // 3. CLI & Collapsible Raw Source Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("③ CLI 目录与底层源码")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button {
                                showRawCodeInDrawer.toggle()
                            } label: {
                                Text(showRawCodeInDrawer ? "收起源码 ▴" : "{ } 展开源码 ▾")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("CLI 启动工作目录").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                DrawerTextField(placeholder: "默认主目录 (~)", text: $draft.workingDirectoryPath)
                                    .onChange(of: draft.workingDirectoryPath) { _, _ in isDirty = true }
                                Button("选择…") {
                                    importerMode = .pickDraftWorkingDirectory
                                }
                                .buttonStyle(MiniPillButtonStyle())
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("附加 CLI 参数 (可选)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            DrawerTextField(placeholder: "例如 --verbose", text: $draft.extraCLIArgs)
                                .onChange(of: draft.extraCLIArgs) { _, _ in isDirty = true }
                        }

                        if showRawCodeInDrawer {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(tab == .codex ? "config.toml" : "settings.json")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("同步表单到源码") {
                                        if let synced = try? manager.synthesizeConfigText(for: draft) {
                                            draft.configText = synced
                                        }
                                    }
                                    .buttonStyle(MiniPillButtonStyle())
                                    if tab != .codex {
                                        Button("格式化") { formatDraftJSON() }
                                            .buttonStyle(MiniPillButtonStyle())
                                    }
                                }
                                CodeTextEditor(text: Binding(
                                    get: { draft.configText },
                                    set: { val in
                                        draft.configText = val
                                        isDirty = true
                                    }
                                ))
                                .frame(height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                }
                .padding(14)
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Drawer Footer
            HStack(spacing: 8) {
                if !draft.active {
                    CardIconButton(
                        icon: "trash",
                        tooltip: "删除此配置",
                        isDestructive: true
                    ) {
                        isDrawerOpen = false
                        manager.deleteProfile(draft, for: tab)
                        syncSelection(for: tab)
                    }
                }

                Button("复制副本") {
                    duplicateAndOpenDrawer(draft)
                }
                .buttonStyle(SecondaryPillButtonStyle())

                Spacer()

                Button("取消") {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                        isDrawerOpen = false
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())

                Button("保存配置") {
                    saveDraft(activate: false, closeDrawer: true)
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .frame(width: 356)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.vertical, 12)
        .padding(.trailing, 12)
    }

    // MARK: - Application Settings Sheet

    private var settingsSheetView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("应用设置", systemImage: "gearshape.fill")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { hideDockOnClose },
                    set: { newValue in
                        hideDockOnClose = newValue
                        lifecycle.hideDockOnClose = newValue
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("关闭主窗口时自动隐藏 Dock 栏图标")
                            .font(.system(size: 13, weight: .medium))
                        Text("开启后，关闭主窗口时应用仅在顶部菜单栏驻留，不占用 Dock 与 ⌘Tab 切换栏。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("默认 CLI 启动工作目录")
                            .font(.system(size: 13, weight: .medium))
                        Text(manager.displayPath(manager.workingDirectory))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("更改目录…") {
                        showSettingsSheet = false
                        importerMode = .pickGlobalWorkingDirectory
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            HStack {
                Spacer()
                Button("完成") {
                    showSettingsSheet = false
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
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

    private func saveDraft(activate: Bool, closeDrawer: Bool) {
        Task {
            do {
                let saved = try await manager.saveProfile(draft, activate: activate)
                selectedProfileID = saved.id
                draft = saved
                isDirty = false
                if closeDrawer {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                        isDrawerOpen = false
                    }
                }
            } catch {
                manager.issue = error.localizedDescription
            }
        }
    }

    // MARK: - Web Profiles Stage

    private var webStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("网页账号")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Button {
                    manager.refresh()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }

            let webItems = manager.profiles[.web, default: []]
            if webItems.isEmpty {
                ContentUnavailableView(
                    "暂无浏览器配置",
                    systemImage: "globe",
                    description: Text("打开 Chrome、Edge、Brave 或 Arc 并登录对应网站后，浏览器配置会自动显示。")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 250, maximum: 460), spacing: 14)
                        ],
                        spacing: 14
                    ) {
                        ForEach(webItems) { profile in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.system(size: 14, weight: .bold))
                                        Text(profile.detail)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if profile.active {
                                        Text("最近使用")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2.5)
                                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    }
                                }
                                Divider().opacity(0.5)
                                HStack(spacing: 8) {
                                    CardIconButton(icon: "pencil", tooltip: "重命名") {
                                        browserRenameText = profile.name
                                        renamingBrowserProfile = profile
                                    }
                                    Spacer()
                                    ForEach(WebService.allCases) { service in
                                        Button("打开 \(service.rawValue)") {
                                            manager.openWeb(profile, service: service)
                                        }
                                        .buttonStyle(PrimaryPillButtonStyle())
                                    }
                                }
                            }
                            .padding(14)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 13))
                            .overlay(
                                RoundedRectangle(cornerRadius: 13)
                                    .strokeBorder(profile.active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Custom Styled Components (Replaces Ugly System Default Controls)

private struct CardIconButton: View {
    let icon: String
    let tooltip: String
    var highlighted = false
    var isDestructive = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(
                    isDestructive
                        ? (isHovered ? Color.red : Color.secondary)
                        : (highlighted ? Color.accentColor : (isHovered ? Color.primary : Color.secondary))
                )
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            highlighted
                                ? Color.accentColor.opacity(0.15)
                                : (isHovered ? Color.primary.opacity(0.09) : Color.primary.opacity(0.04))
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovered = $0 }
    }
}

private struct DrawerTextField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.12),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
    }
}

private struct DrawerSecureField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.12),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
    }
}

private struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1.0))
            )
            .contentShape(Rectangle())
    }
}

private struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

private struct MiniPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07))
            )
            .contentShape(Rectangle())
    }
}

private struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String

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
