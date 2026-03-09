//
//  AppCoordinatorContextFlowTests.swift
//  PindropTests
//
//  Created on 2026-02-09.
//

import ApplicationServices
import XCTest

@testable import Pindrop

@MainActor
final class AppCoordinatorContextFlowTests: XCTestCase {

    var contextEngine: ContextEngineService!
    var mockAXProvider: MockAXProvider!
    var fakeAppElement: AXUIElement!
    var fakeFocusedWindow: AXUIElement!
    var fakeFocusedElement: AXUIElement!

    override func setUp() async throws {
        mockAXProvider = MockAXProvider()
        fakeAppElement = AXUIElementCreateApplication(88880)
        fakeFocusedWindow = AXUIElementCreateApplication(88881)
        fakeFocusedElement = AXUIElementCreateApplication(88882)

        mockAXProvider.frontmostAppElement = fakeAppElement
        mockAXProvider.frontmostPID = 88880
        mockAXProvider.isTrusted = true

        mockAXProvider.setStringAttribute(kAXTitleAttribute, of: fakeAppElement, value: "Xcode")
        mockAXProvider.setElementAttribute(kAXFocusedWindowAttribute, of: fakeAppElement, value: fakeFocusedWindow)
        mockAXProvider.setStringAttribute(kAXTitleAttribute, of: fakeFocusedWindow, value: "AppCoordinator.swift")
        mockAXProvider.setElementAttribute(kAXFocusedUIElementAttribute, of: fakeAppElement, value: fakeFocusedElement)
        mockAXProvider.setStringAttribute(kAXRoleAttribute, of: fakeFocusedElement, value: "AXTextArea")
        mockAXProvider.setStringAttribute(kAXSelectedTextAttribute, of: fakeFocusedElement, value: "func startRecording()")

        contextEngine = ContextEngineService(axProvider: mockAXProvider)
    }

    override func tearDown() async throws {
        contextEngine = nil
        mockAXProvider = nil
        fakeAppElement = nil
        fakeFocusedWindow = nil
        fakeFocusedElement = nil
    }

    // MARK: - Tests

    func testEnhancementUsesContextEngineSnapshot() {
        let result = contextEngine.captureAppContext()

        let snapshot = ContextSnapshot(
            timestamp: Date(),
            appContext: result.appContext,
            clipboardText: nil,
            warnings: result.warnings
        )

        XCTAssertNotNil(snapshot.appContext, "Snapshot should contain app context when AX is trusted")
        XCTAssertTrue(snapshot.warnings.isEmpty, "No warnings expected for trusted AX capture")
        XCTAssertTrue(snapshot.hasAnyContext, "Snapshot should report having context")

        let ctx = snapshot.appContext!
        XCTAssertEqual(ctx.windowTitle, "AppCoordinator.swift")
        XCTAssertEqual(ctx.focusedElementRole, "AXTextArea")
        XCTAssertEqual(ctx.selectedText, "func startRecording()")
        XCTAssertTrue(ctx.hasDetailedContext, "Context with window title and selected text should be detailed")

        let legacy = snapshot.asCapturedContext
        XCTAssertNil(legacy.clipboardText, "Legacy bridge should have nil clipboard text when not captured")

        XCTAssertTrue(AppCoordinator.shouldSuppressEscapeEvent(isRecording: true, isProcessing: false))
        XCTAssertTrue(AppCoordinator.shouldSuppressEscapeEvent(isRecording: false, isProcessing: true))
        XCTAssertFalse(AppCoordinator.shouldSuppressEscapeEvent(isRecording: false, isProcessing: false))

        let now = Date()
        XCTAssertTrue(
            AppCoordinator.isDoubleEscapePress(
                now: now,
                lastEscapeTime: now.addingTimeInterval(-0.2),
                threshold: 0.4
            )
        )
        XCTAssertFalse(
            AppCoordinator.isDoubleEscapePress(
                now: now,
                lastEscapeTime: now.addingTimeInterval(-0.6),
                threshold: 0.4
            )
        )
    }

    func testContextTimeoutFallsBackWithoutBlockingTranscription() {
        mockAXProvider.isTrusted = false

        let result = contextEngine.captureAppContext()

        let snapshot = ContextSnapshot(
            timestamp: Date(),
            appContext: result.appContext,
            clipboardText: "some clipboard text",
            warnings: result.warnings
        )

        XCTAssertTrue(
            snapshot.warnings.contains(.accessibilityPermissionDenied),
            "Should have accessibility permission denied warning"
        )
        XCTAssertTrue(snapshot.hasAnyContext, "Snapshot should still report context from clipboard")
        XCTAssertEqual(snapshot.clipboardText, "some clipboard text", "Clipboard text should be preserved")

        let legacy = snapshot.asCapturedContext
        XCTAssertEqual(legacy.clipboardText, "some clipboard text", "Legacy bridge should preserve clipboard text")
    }

    func testEscapeSuppressionOnlyWhenRecordingOrProcessing() {
        XCTAssertTrue(AppCoordinator.shouldSuppressEscapeEvent(isRecording: true, isProcessing: false))
        XCTAssertTrue(AppCoordinator.shouldSuppressEscapeEvent(isRecording: false, isProcessing: true))
        XCTAssertTrue(AppCoordinator.shouldSuppressEscapeEvent(isRecording: true, isProcessing: true))
        XCTAssertFalse(AppCoordinator.shouldSuppressEscapeEvent(isRecording: false, isProcessing: false))
    }

    func testDoubleEscapeDetectionHonorsThreshold() {
        let now = Date()
        let withinThreshold = now.addingTimeInterval(-0.25)
        let outsideThreshold = now.addingTimeInterval(-0.6)

        XCTAssertTrue(AppCoordinator.isDoubleEscapePress(now: now, lastEscapeTime: withinThreshold, threshold: 0.4))
        XCTAssertFalse(AppCoordinator.isDoubleEscapePress(now: now, lastEscapeTime: outsideThreshold, threshold: 0.4))
        XCTAssertFalse(AppCoordinator.isDoubleEscapePress(now: now, lastEscapeTime: nil, threshold: 0.4))
    }

    func testEventTapRecoveryReenablesForFirstDisableInWindow() {
        let now = Date()

        let decision = AppCoordinator.determineEventTapRecovery(
            now: now,
            lastDisableAt: now.addingTimeInterval(-0.2),
            consecutiveDisableCount: 1,
            disableLoopWindow: 1.0,
            maxReenableAttemptsBeforeRecreate: 3
        )

        XCTAssertEqual(decision.consecutiveDisableCount, 2)
        XCTAssertEqual(decision.action, .reenable)
    }

    func testEventTapRecoveryRecreatesAfterRepeatedDisablesInWindow() {
        let now = Date()

        let decision = AppCoordinator.determineEventTapRecovery(
            now: now,
            lastDisableAt: now.addingTimeInterval(-0.15),
            consecutiveDisableCount: 2,
            disableLoopWindow: 1.0,
            maxReenableAttemptsBeforeRecreate: 3
        )

        XCTAssertEqual(decision.consecutiveDisableCount, 3)
        XCTAssertEqual(decision.action, .recreate)
    }

    func testEventTapRecoveryResetsDisableBurstOutsideWindow() {
        let now = Date()

        let decision = AppCoordinator.determineEventTapRecovery(
            now: now,
            lastDisableAt: now.addingTimeInterval(-1.5),
            consecutiveDisableCount: 5,
            disableLoopWindow: 1.0,
            maxReenableAttemptsBeforeRecreate: 3
        )

        XCTAssertEqual(decision.consecutiveDisableCount, 1)
        XCTAssertEqual(decision.action, .reenable)
    }

    func testNormalizedTranscriptionTextTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(AppCoordinator.normalizedTranscriptionText("  hello world \n"), "hello world")
        XCTAssertEqual(AppCoordinator.normalizedTranscriptionText("\n\t  "), "")
    }

    func testIsTranscriptionEffectivelyEmptyTreatsBlankAudioPlaceholderAsEmpty() {
        XCTAssertTrue(AppCoordinator.isTranscriptionEffectivelyEmpty(""))
        XCTAssertTrue(AppCoordinator.isTranscriptionEffectivelyEmpty("   \n\t"))
        XCTAssertTrue(AppCoordinator.isTranscriptionEffectivelyEmpty("[BLANK AUDIO]"))
        XCTAssertTrue(AppCoordinator.isTranscriptionEffectivelyEmpty("  [blank audio]  "))

        XCTAssertFalse(AppCoordinator.isTranscriptionEffectivelyEmpty("[BLANK AUDIO] detected speech"))
        XCTAssertFalse(AppCoordinator.isTranscriptionEffectivelyEmpty("transcribed text"))
    }

    func testShouldPersistHistoryRequiresSuccessfulOutputAndNonEmptyText() {
        XCTAssertTrue(AppCoordinator.shouldPersistHistory(outputSucceeded: true, text: "transcribed text"))

        XCTAssertFalse(AppCoordinator.shouldPersistHistory(outputSucceeded: false, text: "transcribed text"))
        XCTAssertFalse(AppCoordinator.shouldPersistHistory(outputSucceeded: true, text: "   "))
        XCTAssertFalse(AppCoordinator.shouldPersistHistory(outputSucceeded: true, text: "[BLANK AUDIO]"))
    }

    func testShouldUseStreamingTranscriptionTruthTable() {
        XCTAssertTrue(
            AppCoordinator.shouldUseStreamingTranscription(
                streamingFeatureEnabled: true,
                outputMode: .directInsert,
                aiEnhancementEnabled: false,
                isQuickCaptureMode: false
            )
        )

        XCTAssertFalse(
            AppCoordinator.shouldUseStreamingTranscription(
                streamingFeatureEnabled: false,
                outputMode: .directInsert,
                aiEnhancementEnabled: false,
                isQuickCaptureMode: false
            )
        )

        XCTAssertFalse(
            AppCoordinator.shouldUseStreamingTranscription(
                streamingFeatureEnabled: true,
                outputMode: .clipboard,
                aiEnhancementEnabled: false,
                isQuickCaptureMode: false
            )
        )

        XCTAssertFalse(
            AppCoordinator.shouldUseStreamingTranscription(
                streamingFeatureEnabled: true,
                outputMode: .directInsert,
                aiEnhancementEnabled: true,
                isQuickCaptureMode: false
            )
        )

        XCTAssertFalse(
            AppCoordinator.shouldUseStreamingTranscription(
                streamingFeatureEnabled: true,
                outputMode: .directInsert,
                aiEnhancementEnabled: false,
                isQuickCaptureMode: true
            )
        )
    }

    func testShouldUseSpeakerDiarizationTruthTable() {
        XCTAssertTrue(
            AppCoordinator.shouldUseSpeakerDiarization(
                diarizationFeatureEnabled: true,
                isStreamingSessionActive: false
            )
        )

        XCTAssertFalse(
            AppCoordinator.shouldUseSpeakerDiarization(
                diarizationFeatureEnabled: false,
                isStreamingSessionActive: false
            )
        )

        XCTAssertFalse(
            AppCoordinator.shouldUseSpeakerDiarization(
                diarizationFeatureEnabled: true,
                isStreamingSessionActive: true
            )
        )

        XCTAssertFalse(
            AppCoordinator.shouldUseSpeakerDiarization(
                diarizationFeatureEnabled: false,
                isStreamingSessionActive: true
            )
        )
    }
}
