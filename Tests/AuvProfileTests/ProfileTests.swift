import AppKit
import Foundation
import XCTest
@testable import AuvProfile

final class ProfileTests: XCTestCase {
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
