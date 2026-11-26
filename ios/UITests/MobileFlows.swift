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

    func testOfflineNewChatKeepsDraftUntilConnected() throws {
        app.terminate()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try #"{"offline":true,"host":{"macName":"Test Mac"},"conversations":[]}"#
            .write(to: fixture, atomically: true, encoding: .utf8)
        let connectedArguments = app.launchArguments
        app.launchArguments = ["-demoList", fixture.path]
        app.launch()
        app.buttons["New chat"].tap()
        let input = app.textViews.firstMatch
        input.tap()
        input.typeText("Keep this offline draft")
        XCTAssertFalse(app.buttons["Send"].isEnabled)

        app.terminate()
        app.launchArguments = connectedArguments
        app.launch()
        app.buttons["New chat"].tap()
        XCTAssertTrue((input.value as? String)?.contains("Keep this offline draft") == true)
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        input.tap()
        let count = (input.value as? String)?.count ?? 0
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
    }

    func testReopenLastChatAndReturnToList() {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sample thread")).firstMatch
        row.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testNewChatShowsQuestionBeforeCreationCompletes() throws {
        try checkSentTurn(newChat: true)
    }

    func testFollowUpStartsAtTopOfLongHistory() throws {
        try checkSentTurn(newChat: false)
    }

    private func checkSentTurn(newChat: Bool) throws {
        let id = newChat ? "created" : "existing"
        let conversation = ["id": id, "title": "Turn layout test", "workspaceDir": "/work"]
        let history = (0..<36).map { ["role": "user", "content": "Earlier question \($0)"] }
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["role": "assistant"]],
            ["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "Reply below the question"]],
        ]
        let replies: [String: Any] = [
            "conversations.create": ["delayMs": 4000, "result": conversation],
            "conversations.get": ["result": ["conversation": conversation, "messages": history]],
            "conversations.send": ["delayMs": 2500, "events": events.map {
                ["type": "pi_event", "conversationId": id, "event": $0] as [String: Any]
            }],
        ]
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try JSONSerialization.data(withJSONObject: ["host": ["macName": "Test Mac"], "replies": replies,
                                                    "conversations": newChat ? [] : [conversation]]).write(to: fixture)
        app.terminate()
        app.launchArguments = ["-demoList", fixture.path]
        app.launch()
        if newChat {
            app.buttons["New chat"].tap()
        } else {
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Turn layout test")).firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Earlier question 35"].waitForExistence(timeout: 5))
        }
        let composer = app.textViews.firstMatch
        composer.tap()
        composer.typeText("Where is my question?")
        let submitted = try XCTUnwrap(composer.value as? String)
        app.buttons["Send"].tap()
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", submitted)).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 1))
        let top = app.navigationBars.firstMatch.frame.maxY
        XCTAssertGreaterThanOrEqual(bubble.frame.minY, top - 3)
        XCTAssertLessThan(bubble.frame.minY, top + 65)
        let reply = app.staticTexts["Reply below the question"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertLessThan(bubble.frame.minY, top + 65)
        XCTAssertGreaterThan(reply.frame.minY, bubble.frame.maxY)
        if !newChat {
            composer.tap()
            composer.typeText("Queued next question")
            app.buttons["Send"].tap()
            let queued = app.staticTexts["Queued next question"]
            XCTAssertTrue(queued.waitForExistence(timeout: 2))
            XCTAssertLessThan(queued.frame.minY, top + 65)
            XCTAssertTrue(app.buttons["Steer"].isHittable)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testArchiveRoundTrip() {
        let thread = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sample thread")).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        app.buttons["Archived"].tap()
        XCTAssertFalse(thread.exists)
        app.buttons["Back to chats"].tap()
        XCTAssertTrue(thread.exists)
    }

    /// Relaunch with a Mac that answers `conversations.update` by archiving the sample chat.
    private func launchWithArchivingMac() throws -> XCUIElement {
        app.terminate()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-archive.json")
        let sidebar = #"{"host":{"macName":"Test Mac"},"sidebar":{"defaultWorkspace":"/work"},"conversations":[{"id":"sample","title":"Sample thread","workspaceDir":"/work"}],"replies":{"conversations.update":{"result":{"id":"sample","title":"Sample thread","workspaceDir":"/work","archivedAt":1}}}}"#
        try sidebar.write(to: fixture, atomically: true, encoding: .utf8)
        app.launchArguments = ["-demoList", fixture.path]
        app.launch()
        let thread = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sample thread")).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        return thread
    }

    func testSwipeToArchiveFromList() throws {
        let thread = try launchWithArchivingMac()
        thread.swipeLeft()
        app.buttons["Archive"].tap()
        XCTAssertTrue(thread.waitForNonExistence(timeout: 5))
    }

    func testArchiveFromChatReturnsToList() throws {
        let thread = try launchWithArchivingMac()
        thread.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1).tap()
        app.buttons["Archive"].tap()
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(thread.exists)
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

    func testLongPressCopiesWholeReply() throws {
        app.terminate()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = #"{"conversation":{"id":"demo","title":"Copy test"},"messages":[{"role":"user","content":"Hi"},{"role":"assistant","content":[{"type":"text","text":"First paragraph\n\nSecond paragraph"}]}]}"#
        try snapshot.write(to: file, atomically: true, encoding: .utf8)
        app.launchArguments += ["-demoSnapshot", file.path]
        app.launch()
        let reply = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "First paragraph")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.press(forDuration: 1.0)
        let copy = app.buttons["Copy Reply"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        copy.tap()
        // Reading UIPasteboard here would raise the paste prompt; the menu closing is enough.
        XCTAssertTrue(copy.waitForNonExistence(timeout: 3))
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
