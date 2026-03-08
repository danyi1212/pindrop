//
//  MediaIngestionServiceTests.swift
//  Pindrop
//
//  Created on 2026-03-07.
//

import XCTest
@testable import Pindrop

@MainActor
final class MediaIngestionServiceTests: XCTestCase {
    private let fakeYTDLPPath = "/tmp/pindrop-test-yt-dlp"
    private let fakeFFmpegPath = "/tmp/pindrop-test-ffmpeg"

    func testImportLocalFileCopiesIntoManagedLibrary() async throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
        try Data("audio-data".utf8).write(to: sourceURL)

        let library = ManagedMediaLibrary()
        let asset = try await library.importLocalFile(at: sourceURL, jobID: UUID())

        XCTAssertEqual(asset.sourceKind, .importedFile)
        XCTAssertEqual(asset.displayName, sourceURL.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.mediaURL.path))
        XCTAssertEqual(try Data(contentsOf: asset.mediaURL), Data("audio-data".utf8))

        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: asset.directoryURL)
    }

    func testIngestFileDelegatesToMediaLibrary() async throws {
        let expectedAsset = ManagedMediaAsset(
            directoryURL: URL(fileURLWithPath: "/tmp/job"),
            mediaURL: URL(fileURLWithPath: "/tmp/job/media.mp4"),
            thumbnailURL: nil,
            sourceKind: .importedFile,
            displayName: "media.mp4",
            originalSourceURL: nil
        )
        let library = MockMediaLibrary()
        library.importedAsset = expectedAsset
        let sut = MediaIngestionService(
            processRunner: MockProcessRunner(),
            mediaLibrary: library
        )
        let fileURL = URL(fileURLWithPath: "/tmp/source.mov")

        let asset = try await sut.ingest(
            request: .file(fileURL),
            jobID: UUID(),
            progressHandler: { _, _ in }
        )

        XCTAssertEqual(asset, expectedAsset)
        XCTAssertEqual(library.importedSourceURL, fileURL)
    }

    func testIngestLinkThrowsWhenRequiredToolingIsMissing() async throws {
        let processRunner = MockProcessRunner()
        processRunner.responses = [
            .which(tool: "yt-dlp", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeYTDLPPath)\n", standardError: "")),
            .which(tool: "ffmpeg", result: ProcessExecutionResult(terminationStatus: 1, standardOutput: "", standardError: ""))
        ]
        processRunner.expectedYTDLPPath = fakeYTDLPPath
        processRunner.expectedFFmpegPath = fakeFFmpegPath
        let sut = MediaIngestionService(
            processRunner: processRunner,
            mediaLibrary: MockMediaLibrary(),
            toolPathResolver: { _ in nil }
        )

        await XCTAssertThrowsErrorAsync(
            try await sut.ingest(
                request: .link("https://example.com/video"),
                jobID: UUID(),
                progressHandler: { _, _ in }
            )
        ) { error in
            guard case MediaIngestionError.toolingUnavailable(let message) = error else {
                return XCTFail("Expected toolingUnavailable error, got \(error)")
            }
            XCTAssertEqual(message, "To transcribe web links, install ffmpeg.")
        }
    }

    func testIngestLinkDownloadsMediaAndReportsProgress() async throws {
        let jobID = UUID()
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(jobID.uuidString, isDirectory: true)
        let finalizedAsset = ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: directoryURL.appendingPathComponent("media.mp4"),
            thumbnailURL: directoryURL.appendingPathComponent("thumbnail.png"),
            sourceKind: .webLink,
            displayName: "Example title",
            originalSourceURL: "https://example.com/video"
        )
        let processRunner = MockProcessRunner()
        processRunner.responses = [
            .which(tool: "yt-dlp", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeYTDLPPath)\n", standardError: "")),
            .which(tool: "ffmpeg", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeFFmpegPath)\n", standardError: "")),
            .metadata(
                url: "https://example.com/video",
                result: ProcessExecutionResult(
                    terminationStatus: 0,
                    standardOutput: #"{"title":"Example title","webpage_url":"https://example.com/video"}"#,
                    standardError: ""
                )
            ),
            .download(
                url: "https://example.com/video",
                result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "", standardError: ""),
                emittedLines: [
                    "[download] Destination: media.mp4",
                    "[download] 42.0% of 10.00MiB at 1.00MiB/s ETA 00:06"
                ]
            )
        ]
        processRunner.expectedYTDLPPath = fakeYTDLPPath
        processRunner.expectedFFmpegPath = fakeFFmpegPath
        let library = MockMediaLibrary()
        library.directoryURL = directoryURL
        library.finalizedAsset = finalizedAsset
        let sut = MediaIngestionService(
            processRunner: processRunner,
            mediaLibrary: library,
            toolPathResolver: { _ in nil }
        )
        var reportedProgress: [(Double?, String)] = []

        let asset = try await sut.ingest(
            request: .link("https://example.com/video"),
            jobID: jobID,
            progressHandler: { progress, detail in
                reportedProgress.append((progress, detail))
            }
        )

        XCTAssertEqual(asset, finalizedAsset)
        XCTAssertEqual(library.makeJobDirectoryCallCount, 1)
        XCTAssertEqual(library.finalizeDirectoryURL, directoryURL)
        XCTAssertEqual(library.finalizeSourceURL, "https://example.com/video")
        XCTAssertEqual(library.finalizeSuggestedTitle, "Example title")
        XCTAssertTrue(reportedProgress.contains(where: { $0.1 == "Preparing download" }))
        XCTAssertTrue(reportedProgress.contains(where: { ($0.0 ?? 0) == 0.42 && $0.1 == "Downloading media" }))
    }

    func testIngestYouTubeLinkRetriesWithCompatibilityFallbackAfter403() async throws {
        let jobID = UUID()
        let youtubeURL = "https://www.youtube.com/watch?v=abc123"
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(jobID.uuidString, isDirectory: true)
        let finalizedAsset = ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: directoryURL.appendingPathComponent("media.mp4"),
            thumbnailURL: directoryURL.appendingPathComponent("thumbnail.png"),
            sourceKind: .webLink,
            displayName: "Example video",
            originalSourceURL: youtubeURL
        )

        let processRunner = MockProcessRunner()
        processRunner.responses = [
            .which(tool: "yt-dlp", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeYTDLPPath)\n", standardError: "")),
            .which(tool: "ffmpeg", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeFFmpegPath)\n", standardError: "")),
            .metadata(
                url: youtubeURL,
                result: ProcessExecutionResult(
                    terminationStatus: 0,
                    standardOutput: #"{"title":"Example video","webpage_url":"https://www.youtube.com/watch?v=abc123"}"#,
                    standardError: ""
                )
            ),
            .download(
                url: youtubeURL,
                strategy: .standard,
                result: ProcessExecutionResult(
                    terminationStatus: 1,
                    standardOutput: "",
                    standardError: "ERROR: unable to download video data: HTTP Error 403: Forbidden\nWARNING: Some web client https formats have been skipped as they are missing a url."
                ),
                emittedLines: []
            ),
            .download(
                url: youtubeURL,
                strategy: .youtubeCompatibility,
                result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "", standardError: ""),
                emittedLines: [
                    "[download] Destination: media.mp4"
                ]
            )
        ]
        processRunner.expectedYTDLPPath = fakeYTDLPPath
        processRunner.expectedFFmpegPath = fakeFFmpegPath

        let library = MockMediaLibrary()
        library.directoryURL = directoryURL
        library.finalizedAsset = finalizedAsset

        let sut = MediaIngestionService(
            processRunner: processRunner,
            mediaLibrary: library,
            toolPathResolver: { _ in nil }
        )

        let asset = try await sut.ingest(
            request: .link(youtubeURL),
            jobID: jobID,
            progressHandler: { _, _ in }
        )

        XCTAssertEqual(asset, finalizedAsset)
        XCTAssertEqual(library.finalizeSourceURL, youtubeURL)
        XCTAssertEqual(library.finalizeSuggestedTitle, "Example video")
    }
}

private final class MockMediaLibrary: MediaLibraryManaging {
    var importedSourceURL: URL?
    var importedAsset = ManagedMediaAsset(
        directoryURL: URL(fileURLWithPath: "/tmp/job"),
        mediaURL: URL(fileURLWithPath: "/tmp/job/media.mp4"),
        thumbnailURL: nil,
        sourceKind: .importedFile,
        displayName: "media.mp4",
        originalSourceURL: nil
    )
    var directoryURL = URL(fileURLWithPath: "/tmp/job", isDirectory: true)
    var finalizedAsset = ManagedMediaAsset(
        directoryURL: URL(fileURLWithPath: "/tmp/job"),
        mediaURL: URL(fileURLWithPath: "/tmp/job/media.mp4"),
        thumbnailURL: nil,
        sourceKind: .webLink,
        displayName: "media.mp4",
        originalSourceURL: nil
    )
    var makeJobDirectoryCallCount = 0
    var finalizeDirectoryURL: URL?
    var finalizeSourceURL: String?
    var finalizeSuggestedTitle: String?

    func makeJobDirectory(for jobID: UUID) throws -> URL {
        makeJobDirectoryCallCount += 1
        return directoryURL
    }

    func importLocalFile(at sourceURL: URL, jobID: UUID) async throws -> ManagedMediaAsset {
        importedSourceURL = sourceURL
        return importedAsset
    }

    func finalizeDownloadedAsset(
        in directoryURL: URL,
        sourceURL: String,
        suggestedTitle: String?
    ) async throws -> ManagedMediaAsset {
        finalizeDirectoryURL = directoryURL
        finalizeSourceURL = sourceURL
        finalizeSuggestedTitle = suggestedTitle
        return finalizedAsset
    }
}

private final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    enum DownloadStrategy {
        case standard
        case youtubeCompatibility
    }

    enum Response {
        case which(tool: String, result: ProcessExecutionResult)
        case metadata(url: String, result: ProcessExecutionResult)
        case download(url: String, strategy: DownloadStrategy = .standard, result: ProcessExecutionResult, emittedLines: [String])
    }

    var responses: [Response] = []
    var expectedYTDLPPath = "/tmp/pindrop-test-yt-dlp"
    var expectedFFmpegPath = "/tmp/pindrop-test-ffmpeg"

    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String : String]?,
        lineHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessExecutionResult {
        guard let responseIndex = responses.firstIndex(where: { response in
            matches(response: response, executableURL: executableURL, arguments: arguments)
        }) else {
            XCTFail("Unexpected process invocation: \(executableURL.path) \(arguments.joined(separator: " "))")
            return ProcessExecutionResult(terminationStatus: 1, standardOutput: "", standardError: "Unexpected process call")
        }

        let response = responses.remove(at: responseIndex)

        switch response {
        case .which(let tool, let result):
            XCTAssertEqual(executableURL.path, "/usr/bin/which")
            XCTAssertEqual(arguments, [tool])
            XCTAssertNotNil(environment?["PATH"])
            return result

        case .metadata(let url, let result):
            XCTAssertEqual(executableURL.path, expectedYTDLPPath)
            XCTAssertEqual(arguments, [
                "--dump-single-json",
                "--no-playlist",
                "--ffmpeg-location", URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path,
                url
            ])
            XCTAssertTrue(environment?["PATH"]?.contains(URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path) == true)
            return result

        case .download(let url, let strategy, let result, let emittedLines):
            XCTAssertEqual(executableURL.path, expectedYTDLPPath)
            XCTAssertEqual(arguments, expectedDownloadArguments(for: url, strategy: strategy))
            XCTAssertTrue(environment?["PATH"]?.contains(URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path) == true)
            emittedLines.forEach { lineHandler?($0) }
            return result
        }
    }

    private func matches(response: Response, executableURL: URL, arguments: [String]) -> Bool {
        switch response {
        case .which(let tool, _):
            return executableURL.path == "/usr/bin/which" && arguments == [tool]
        case .metadata(let url, _):
            return executableURL.path == expectedYTDLPPath
                && arguments == [
                    "--dump-single-json",
                    "--no-playlist",
                    "--ffmpeg-location", URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path,
                    url
                ]
        case .download(let url, let strategy, _, _):
            return executableURL.path == expectedYTDLPPath
                && arguments == expectedDownloadArguments(for: url, strategy: strategy)
        }
    }

    private func expectedDownloadArguments(for url: String, strategy: DownloadStrategy) -> [String] {
        let ffmpegDirectory = URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path

        switch strategy {
        case .standard:
            return [
                "--no-playlist",
                "--newline",
                "--progress",
                "--format", "bestvideo*+bestaudio/best",
                "--merge-output-format", "mp4",
                "--ffmpeg-location", ffmpegDirectory,
                "--write-thumbnail",
                "--convert-thumbnails", "png",
                "-o", "media.%(ext)s",
                url
            ]
        case .youtubeCompatibility:
            return [
                "--no-playlist",
                "--newline",
                "--progress",
                "--extractor-args", "youtube:player_client=default,-web,-web_safari,-web_creator",
                "--format", "best[ext=mp4]/best",
                "--ffmpeg-location", ffmpegDirectory,
                "--write-thumbnail",
                "--convert-thumbnails", "png",
                "-o", "media.%(ext)s",
                url
            ]
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
