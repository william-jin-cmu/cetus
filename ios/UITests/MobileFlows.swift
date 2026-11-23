import XCTest

final class MobileFlows: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar.json")
        let sidebar = #"{"host":{"macName":"Test Mac"},"sidebar":{"defaultWorkspace":"/work"},"conversations":[{"id":"sample","title":"Sample thread","workspaceDir":"/work"}]}"#
        try sidebar.write(to: fixture, atomically: true, encoding: .utf8)
        app.launchArguments = ["-demoList", fixture.path]
        app.launch()
    }

    func testArchiveRoundTrip() {
        let thread = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sample thread")).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        app.buttons["Archived"].tap()
        XCTAssertFalse(thread.exists)
        app.buttons["Back to chats"].tap()
        XCTAssertTrue(thread.exists)
    }

    func testSettingsPairValidationAndUsage() {
        app.buttons["Settings"].tap()
        app.buttons["Pair Another Mac…"].tap()
        let link = app.textFields.firstMatch
        link.tap()
        link.typeText("invalid\n")
        XCTAssertTrue(app.staticTexts["That isn't a Cetus pairing code."].exists)
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        app.buttons["Usage"].tap()
        XCTAssertTrue(app.navigationBars["Usage"].exists)
        app.buttons["Done"].tap()
        app.buttons["Add folder"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Add folder"].exists)
        app.buttons["Cancel"].tap()
    }

    func testRetryAfterHistoryBecomesAvailable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        app.terminate()
        app.launchArguments += ["-demoSnapshot", file.path]
        app.launch()
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let snapshot = #"{"conversation":{"id":"demo"},"messages":[{"role":"user","content":"Recovered history"}]}"#
        try snapshot.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        retry.tap()
        XCTAssertTrue(app.staticTexts["Recovered history"].waitForExistence(timeout: 5))
        XCTAssertFalse(retry.exists)
    }

    func testDocumentPreviewFromTranscript() throws {
        let directory = FileManager.default.temporaryDirectory
        let document = directory.appendingPathComponent("qa-note.txt")
        try "Simulator artifact preview".write(to: document, atomically: true, encoding: .utf8)
        let snapshot: [String: Any] = [
            "conversation": ["id": "demo", "title": "Artifact test"],
            "messages": [
                ["role": "assistant", "content": [["type": "toolCall", "name": "send_artifact", "id": "file"]]],
                ["role": "toolResult", "toolCallId": "file", "details": [
                    "kind": "artifact", "path": document.path, "sizeBytes": 26,
                ]],
            ],
        ]
        let file = directory.appendingPathComponent("transcript.json")
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        app.terminate()
        app.launchArguments += ["-demoSnapshot", file.path]
        app.launch()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", document.lastPathComponent)).firstMatch.tap()
        XCTAssertTrue(app.navigationBars[document.lastPathComponent].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Simulator artifact preview")).firstMatch.exists)
    }

    func testRuntimeAndFolderPicker() {
        app.buttons["New chat"].tap()
        let runtime = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Runtime,")).firstMatch
        let choice = runtime.label.contains("Codex") ? "Claude Code" : "Codex"
        runtime.tap()
        app.buttons[choice].tap()
        XCTAssertTrue(runtime.label.contains(choice))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Folder,")).firstMatch.tap()
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("missing-folder")
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "/work")).firstMatch.exists)
        app.buttons["Add folder"].tap()
        XCTAssertTrue(app.navigationBars["Add folder"].exists)
        app.buttons["Cancel"].tap()
    }

    func testNewChatComposer() {
        app.buttons["New chat"].tap()
        XCTAssertTrue(app.navigationBars["New chat"].exists)
        let composer = app.textViews.firstMatch
        composer.tap()
        let input = "Simulator draft"
        composer.typeText(input)
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: input.count))
        app.buttons["Attach photos"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5) || app.buttons["Close"].exists)
    }
}
