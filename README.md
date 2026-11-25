# AuvProfile

AuvProfile 是一个本地 macOS 应用。可以在菜单栏快速打开或切换 AI 客户端的 profile，也可以在主窗口编辑服务商和配置文件。

| 客户端 | 支持内容 |
| --- | --- |
| ChatGPT / Codex | 从 Codex 的文件认证读取当前登录，可导入现有 `auth.json`。在「登录新账号」完成登录后，新账号会自动出现。支持切换 `model_providers`、旧版 `[profiles]` 和独立 `*.config.toml`。 |
| Claude Code | 识别默认目录、`CLAUDE_CONFIG_DIR`、`~/.claude-*` 和 `~/.claude/profiles/` 下的现有 profile。支持导入或新建独立目录、编辑 `settings.json`，并在对应 profile 内登录。 |
| Claude Desktop | 识别已安装的客户端，可编辑本地桌面配置并重启应用。桌面 OAuth 登录在 Claude 内管理。 |
| Antigravity | 识别桌面应用，可重启当前桌面会话。CLI profile 使用官方 `--settings` 参数，可编辑本地 JSON。Google 登录在 Antigravity 内管理。 |
| 网页版 ChatGPT / Claude | 自动发现 Chrome 和 Edge 的浏览器 profile，打开网站时使用该 profile 已有的登录会话。 |

## 安装

需要 macOS 14 或更高版本、Swift 5.10 或更高版本以及 Rust 工具链。可用 `xcode-select --install` 安装 Apple 命令行工具。

```bash
git clone https://github.com/keman5/AuvProfile.git
cd AuvProfile
./build.sh
```

脚本运行测试并将应用安装到 `/Applications/AuvProfile.app`。仅运行测试可用 `./build.sh --test`。

## 使用

- **Codex 账号**。打开应用后，当前文件登录会加入列表。其他账号可使用「登录新账号」或导入现有 `auth.json`。点击「启用」后，已运行的 Codex 桌面端和由 AuvProfile 启动的 Codex CLI 会重启。使用 Codex 原生系统钥匙串、自动凭据存储或第三方宿主注入时，请用对应客户端管理账号。
- **Codex 服务商**。点击「添加服务商」或「编辑」可配置 `base_url`、`env_key`、`experimental_bearer_token`、`wire_api` 和 `requires_openai_auth`。每次编辑会保留其他 TOML 配置和注释。「配置」可打开完整文件。保存编辑后可点「启用」应用并重启。
- **Claude Code 和 Antigravity CLI**。从列表选择或导入配置目录，再点「启用」。使用 CLI 认证命令或交互登录完成客户端登录。终端重启适用于由 AuvProfile 启动的会话。其他终端里已有的 CLI 需要自行退出。
- **网页账号**。先在不同浏览器 profile 中登录目标网站，再从 AuvProfile 的「网页账号」页快速打开。

## 凭据如何保存

Codex 登录快照保存在此 Mac 的钥匙串中。应用写配置前会检查原文件是否已经被修改，替换文件时使用仅当前用户可读取的权限。服务商的 `experimental_bearer_token` 按 Codex 原生格式保存在其本地 TOML 中。浏览器登录会话保留在各自的浏览器 profile 内。

## 许可

MIT
