import AppKit
import SwiftUI

enum MainWindowAction {
    case manage
    case create
    case edit(Profile)
}

struct ClientNavigationButton: View {
    let client: Client
    let selected: Bool
    var fillsRow = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(client.rawValue, systemImage: client.icon)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .padding(.horizontal, 10)
                .frame(maxWidth: fillsRow ? .infinity : nil, alignment: .leading)
                .frame(height: 34)
                .foregroundStyle(selected ? WorkspacePalette.accent : .secondary)
                .background(selected ? WorkspacePalette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MenuBarProfiles: View {
    @ObservedObject var manager: ProfileManager
    let openMainWindow: (Client, MainWindowAction) -> Void
    let closePanel: () -> Void
    @State private var client = Client.codex
    @State private var pendingProfile: Profile?

    private var profiles: [Profile] {
        let rows = manager.profiles[client, default: []]
        return rows.filter(\.active) + rows.filter { !$0.active }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(client.rawValue)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if client != .web {
                        Button("新建配置", systemImage: "plus") { showMainWindow(.create) }
                            .disabled(manager.busy)
                    }
                }
                profileTable
                if manager.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在处理…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let issue = manager.issue {
                    Button {
                        showMainWindow()
                    } label: {
                        Label(issue, systemImage: "exclamationmark.circle")
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .help(issue)
                } else if !manager.status.isEmpty {
                    Text(manager.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 500, height: 394)
        .background(WorkspacePalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspacePalette.line))
        .onExitCommand(perform: closePanel)
        .alert(
            "确认启用配置？",
            isPresented: Binding(
                get: { pendingProfile != nil },
                set: { if !$0 { pendingProfile = nil } }
            ),
            presenting: pendingProfile
        ) { profile in
            Button("确认启用") {
                manager.select(profile, for: profile.client)
                pendingProfile = nil
            }
            Button("取消", role: .cancel) {
                pendingProfile = nil
            }
        } message: { profile in
            Text("即将启用「\(profile.name)」（服务商：\(profile.providerBadge)）。")
        }
    }

    private var tabs: some View {
        HStack(spacing: 3) {
            ForEach(Client.allCases) { item in
                ClientNavigationButton(client: item, selected: client == item) { client = item }
            }
            Spacer(minLength: 2)
            Button("刷新列表", systemImage: "arrow.clockwise", action: manager.refresh)
                .labelStyle(.iconOnly)
                .help("刷新列表")
                .disabled(manager.busy)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(WorkspacePalette.navigation)
    }

    private var profileTable: some View {
        VStack(spacing: 0) {
            columns {
                Text("配置名称")
                Text(client == .web ? "浏览器" : "服务商")
                Text("操作")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(height: 28)
            .background(WorkspacePalette.card)
            Rectangle().fill(WorkspacePalette.line).frame(height: 1)
            if profiles.isEmpty {
                Text(client == .web ? "暂无浏览器配置" : "暂无配置")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 68)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                            if index != 0 { Rectangle().fill(WorkspacePalette.line).frame(height: 1) }
                            row(profile)
                        }
                    }
                }
                .frame(height: min(CGFloat(profiles.count) * 38 + CGFloat(profiles.count - 1), 205))
                .id(client)
            }
        }
        .background(WorkspacePalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspacePalette.line))
    }

    private func row(_ profile: Profile) -> some View {
        columns {
            Group {
                if profile.client == .web {
                    Text(profile.name)
                } else {
                    Button(profile.name) { showMainWindow(.edit(profile)) }
                        .buttonStyle(.plain)
                        .help("在主窗口编辑 \(profile.name)")
                }
            }
            .fontWeight(.medium)
            .lineLimit(1)
            .help(profile.name)

            Text(profile.providerBadge)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(profile.providerBadge)

            if profile.client == .web {
                Menu(profile.active ? "再次打开" : "打开") {
                    ForEach(WebService.allCases) { service in
                        Button(service.rawValue) { manager.openWeb(profile, service: service) }
                    }
                }
                .fixedSize()
            } else if profile.active {
                Text("已启用")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WorkspacePalette.enabled)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WorkspacePalette.enabledBackground, in: Capsule())
            } else {
                Button("启用") { pendingProfile = profile }
                    .help(profile.client == .codex ? "启用后会重启正在运行的客户端" : "启用此配置")
            }
        }
        .controlSize(.small)
        .disabled(manager.busy)
        .frame(height: 38)
    }

    private func columns<Name: View, Detail: View, Actions: View>(
        @ViewBuilder content: () -> TupleView<(Name, Detail, Actions)>
    ) -> some View {
        let (name, detail, actions) = content().value
        return HStack(spacing: 10) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            detail.frame(width: 136, alignment: .leading)
            actions.frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 11)
    }

    private var footer: some View {
        HStack {
            Button("打开主窗口…", systemImage: "macwindow") { showMainWindow() }
            Spacer()
            Menu("更多操作", systemImage: "ellipsis") {
                if client != .web {
                    Button("打开 CLI 终端") { manager.launchCLI(client) }
                        .disabled(manager.busy)
                    Button("打开桌面客户端") { manager.openDesktop(client) }
                        .disabled(manager.busy)
                    if let active = profiles.first(where: \.active) {
                        Button("重新应用当前配置") { manager.select(active, for: client) }
                            .disabled(manager.busy)
                    }
                    Divider()
                }
                Button("退出 AuvProfile") { NSApplication.shared.terminate(nil) }
            }
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func showMainWindow(_ action: MainWindowAction = .manage) {
        openMainWindow(client, action)
    }
}
