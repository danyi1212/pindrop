//
//  MediaTranscriptionFeatureStateTests.swift
//  Pindrop
//
//  Created on 2026-03-07.
//

import XCTest
@testable import Pindrop

@MainActor
final class MediaTranscriptionFeatureStateTests: XCTestCase {
    func testClipboardPrefillDoesNotOverwriteUserEditedDraft() {
        let sut = MediaTranscriptionFeatureState()
        sut.draftLink = "https://user-entered.example"
        sut.hasUserEditedDraftLink = true

        sut.updateDraftLinkFromClipboard("https://clipboard.example")

        XCTAssertEqual(sut.draftLink, "https://user-entered.example")
    }

    func testCompleteCurrentJobNavigatesToDetailWhenRequested() {
        let sut = MediaTranscriptionFeatureState()
        let recordID = UUID()
        let job = MediaTranscriptionJobState(
            id: UUID(),
            request: .link("https://example.com/video"),
            stage: .transcribing,
            progress: 0.8,
            detail: "Transcribing"
        )

        sut.beginJob(job)
        sut.completeCurrentJob(with: recordID, shouldNavigateToDetail: true)

        XCTAssertEqual(sut.route, .detail(recordID))
        XCTAssertEqual(sut.selectedRecordID, recordID)
        XCTAssertEqual(sut.currentJob?.stage, .completed)
        XCTAssertEqual(sut.currentJob?.progress, 1.0)
        XCTAssertEqual(sut.currentJob?.detail, "Saved transcription")
    }

    func testCompleteCurrentJobReturnsToLibraryWhenProcessingViewExited() {
        let sut = MediaTranscriptionFeatureState()
        let recordID = UUID()
        let job = MediaTranscriptionJobState(
            id: UUID(),
            request: .file(URL(fileURLWithPath: "/tmp/example.mov")),
            stage: .preparingAudio,
            detail: "Preparing audio"
        )

        sut.beginJob(job)
        sut.exitProcessingView()
        sut.completeCurrentJob(with: recordID, shouldNavigateToDetail: false)

        XCTAssertEqual(sut.route, .library)
        XCTAssertEqual(sut.selectedRecordID, recordID)
        XCTAssertEqual(sut.libraryMessage, "Transcription finished.")
    }

    func testSelectedFolderPersistsAcrossRouteChanges() {
        let sut = MediaTranscriptionFeatureState()
        let folderID = UUID()
        let recordID = UUID()

        sut.selectFolder(folderID)
        sut.selectRecord(recordID)
        sut.showLibrary()

        XCTAssertEqual(sut.selectedFolderID, folderID)
        XCTAssertEqual(sut.route, .library)
    }

    func testDeletingSelectedFolderClearsFolderSelection() {
        let sut = MediaTranscriptionFeatureState()
        let folderID = UUID()

        sut.selectFolder(folderID)
        sut.handleDeletedFolder(folderID)

        XCTAssertNil(sut.selectedFolderID)
    }

    func testLibrarySearchAndSortStateRemainMutableDuringJobLifecycle() {
        let sut = MediaTranscriptionFeatureState()
        let folderID = UUID()

        sut.librarySearchText = "roadmap"
        sut.librarySortMode = .nameAscending
        sut.selectFolder(folderID)
        sut.beginJob(MediaTranscriptionJobState(request: .link("https://example.com"), destinationFolderID: folderID))
        sut.completeCurrentJob(with: UUID(), shouldNavigateToDetail: false)

        XCTAssertEqual(sut.librarySearchText, "roadmap")
        XCTAssertEqual(sut.librarySortMode, .nameAscending)
        XCTAssertEqual(sut.selectedFolderID, folderID)
    }
}
