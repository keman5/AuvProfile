import AppKit
import Foundation
import XCTest
@testable import AuvProfile

final class ProfileTests: XCTestCase {
    @MainActor
    func testTabFocusRequiresKeyboardNavigation() throws {
        let lifecycle = WindowLifecycle()
        func tab(_ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
            ))
        }

        XCTAssertFalse(lifecycle.showsTabFocus)
        lifecycle.updateTabFocus(for: try tab(.command))
        XCTAssertFalse(lifecycle.showsTabFocus)
        lifecycle.updateTabFocus(for: try tab(.shift))
        XCTAssertTrue(lifecycle.showsTabFocus)

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        lifecycle.updateTabFocus(for: click)
        XCTAssertFalse(lifecycle.showsTabFocus)
        lifecycle.updateTabFocus(for: try tab())
        XCTAssertTrue(lifecycle.showsTabFocus)
    }

    func testCodexAccountIDSurvivesTokenRefresh() throws {
        let claims = Data(#"{"email":"sample@example.test","sub":"synthetic-user"}"#.utf8).base64EncodedString()
        func auth(_ access: String, _ account: String) throws -> CodexAccount {
            let data = try JSONSerialization.data(withJSONObject: ["tokens": [
                "id_token": "header.\(claims).signature", "account_id": account, "access_token": access
            ]])
            return try XCTUnwrap(CodexAccount(data))
        }
        XCTAssertEqual(try auth("old-token", "space1").key, try auth("new-token", "space1").key)
        XCTAssertNotEqual(try auth("old-token", "space1").key, try auth("old-token", "space2").key)
    }

    func testAtomicWriteChecksExpectedContentsAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.toml")
        let first = Data("model = 'example'".utf8)
        let second = Data("model = 'next'".utf8)
        try PrivateFiles.replace(url, expected: nil, with: first)
        XCTAssertThrowsError(try PrivateFiles.replace(url, expected: nil, with: second))
        XCTAssertEqual(try PrivateFiles.read(url), first)
        try PrivateFiles.replace(url, expected: first, with: second)
        XCTAssertEqual(try PrivateFiles.read(url), second)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testProviderRejectsCredentialedURL() {
        XCTAssertThrowsError(try Provider(id: "test", baseUrl: "https://user:password@example.test/v1").validated())
        XCTAssertNoThrow(try Provider(id: "test", baseUrl: "http://127.0.0.1:8080/v1").validated())
    }

    func testSwitchSavesCurrentAccountAndPreservesUnknownAuth() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "auth.json")
        let first = Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-first"}"#.utf8)
        let second = Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-second"}"#.utf8)
        let external = Data(#"{"auth_mode":"chatgptAuthTokens","OPENAI_API_KEY":"synthetic-external"}"#.utf8)

        try PrivateFiles.replace(url, expected: nil, with: first)
        try restoreCodexAuth(second, to: url) { account, data in
            XCTAssertEqual(account, CodexAccount(first))
            XCTAssertEqual(data, first)
        }
        XCTAssertEqual(try PrivateFiles.read(url), second)
        try PrivateFiles.replace(url, expected: second, with: external)
        XCTAssertThrowsError(try restoreCodexAuth(first, to: url) { _, _ in XCTFail("Unknown auth must not be saved") })
        XCTAssertEqual(try PrivateFiles.read(url), external)
    }

    func testProviderHelperRoundTrip() throws {
        let helper = CodexConfigHelper()
        let source = "[model_providers.local]\nname = 'Local'\n"
        let provider = Provider(id: "local", name: "Local", baseUrl: "https://example.test", experimentalBearerToken: "fake-token")
        let result = try helper.call("update", source: source, provider: provider)
        let updated = try helper.call("inspect", source: XCTUnwrap(result.text))
        XCTAssertEqual(updated.providers.first, provider)
        let deleted = try helper.call("delete", source: XCTUnwrap(result.text), id: "local")
        let afterDelete = try helper.call("inspect", source: XCTUnwrap(deleted.text))
        XCTAssertTrue(afterDelete.providers.isEmpty)
    }

    func testDirectAPIKeyAccountDataIsRecognized() throws {
        let data = try CodexAccount.apiKeyData("sk-test-1234567890")
        let account = try XCTUnwrap(CodexAccount(data))
        XCTAssertTrue(account.key.hasPrefix("api-"))
        XCTAssertThrowsError(try CodexAccount.apiKeyData("   "))
    }

    func testManagedAccountValidationForClaudeAndAntigravity() throws {
        let claude = try ManagedAccount(
            client: .claude,
            name: "Claude Pro",
            apiKey: "sk-ant-test-key",
            baseUrl: "https://api.anthropic.com",
            model: "claude-sonnet-4-20250514"
        ).validated()
        XCTAssertTrue(claude.id.hasPrefix("claude-"))
        XCTAssertEqual(claude.name, "Claude Pro")
        XCTAssertTrue(claude.summaryDetail.contains("api.anthropic.com"))

        let agy = try ManagedAccount(
            client: .antigravity,
            name: "",
            apiKey: "AIzaSyTest1234",
            project: "my-gcp-project"
        ).validated()
        XCTAssertTrue(agy.id.hasPrefix("antigravity-"))
        XCTAssertFalse(agy.name.isEmpty)
        XCTAssertTrue(agy.summaryDetail.contains("my-gcp-project"))

        XCTAssertThrowsError(try ManagedAccount(client: .claude, name: "Bad", apiKey: " ").validated())
        XCTAssertThrowsError(try ManagedAccount(client: .claude, name: "Bad URL", apiKey: "sk-123", baseUrl: "https://user:pass@example.com").validated())
    }

    func testUnifiedProfileModelAndChatGPTRename() {
        XCTAssertEqual(Client.codex.rawValue, "ChatGPT")
        let profile = Profile(
            client: .codex,
            name: "OpenRouter 方案",
            authMode: .apiKey,
            apiKey: "sk-12345678",
            providerId: "openrouter",
            providerName: "OpenRouter",
            baseUrl: "https://openrouter.ai/api/v1",
            model: "deepseek-chat"
        )
        XCTAssertEqual(profile.accountBadge, "API Key · 5678")
        XCTAssertEqual(profile.providerBadge, "OpenRouter")
        XCTAssertEqual(profile.cliBadge, "deepseek-chat")
    }

    func testAppIconGeneratesIconset() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try AppIcon.writeIconset(to: directory)
        let data = try Data(contentsOf: directory.appending(path: "icon_512x512@2x.png"))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(image.pixelsWide, 1024)
        XCTAssertEqual(image.pixelsHigh, 1024)
    }
}
